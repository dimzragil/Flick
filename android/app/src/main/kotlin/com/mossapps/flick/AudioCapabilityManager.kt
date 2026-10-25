package com.mossapps.flick

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.MediaCodecList
import android.media.Spatializer
import android.os.Build

/**
 * Manages device audio spatialization and Dolby Atmos (E-AC-3 JOC) hardware capability detection.
 * Logic mirrors the reverse-engineered TIDAL Android capability detection (defpackage.oh4).
 */
class AudioCapabilityManager(private val context: Context) {
    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    fun getAudioCapabilities(): Map<String, Any?> {
        val hasSpatializer = checkSpatializerSupport()
        val hasDeviceEncoding = checkDeviceEncodingSupport()
        val hasDecoder = checkMediaCodecSupport()

        // Supported if Android Spatializer is active, or if the hardware output supports E-AC-3 JOC
        // encoding and the system has an EAC3-JOC decoder.
        val isDolbyAtmosSupported = hasSpatializer || (hasDecoder && hasDeviceEncoding)

        return mapOf(
            "isDolbyAtmosSupported" to isDolbyAtmosSupported,
            "hasSpatializer" to hasSpatializer,
            "hasEac3JocDecoder" to hasDecoder,
            "hasDeviceEncoding" to hasDeviceEncoding
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

    private fun checkDeviceEncodingSupport(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && audioManager != null) {
            return try {
                val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                devices.any { device ->
                    // AudioFormat.ENCODING_E_AC3_JOC = 18
                    device.encodings.contains(18)
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
}
