package com.zarz.mornye

import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioMixerAttributes
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Build

/**
 * Read-only route and stream facts for the player's audio information sheet.
 * Nothing here changes routing, volume or the playing track.
 */
internal object AudioRouteInfo {
    private val media = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()

    fun read(context: Context, path: String?): Map<String, Any?> {
        val manager = context.getSystemService(AudioManager::class.java)
        val features = context.packageManager
        val device = activeDevice(manager)
        return mapOf(
            "platform" to "android",
            "sdk" to Build.VERSION.SDK_INT,
            // These are default low-latency PCM properties, not the negotiated
            // Bluetooth codec rate, bit depth or end-to-end buffer duration.
            "mixerSampleRate" to manager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull(),
            "framesPerBuffer" to manager.getProperty(AudioManager.PROPERTY_OUTPUT_FRAMES_PER_BUFFER)?.toIntOrNull(),
            "lowLatency" to features.hasSystemFeature(PackageManager.FEATURE_AUDIO_LOW_LATENCY),
            "proAudio" to features.hasSystemFeature(PackageManager.FEATURE_AUDIO_PRO),
            "volume" to manager.getStreamVolume(AudioManager.STREAM_MUSIC),
            "maxVolume" to manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
            "fixedVolume" to manager.isVolumeFixed,
            "device" to device?.let { describe(manager, it) },
            "spatializer" to spatializer(manager),
            "stream" to path?.let { runCatching { stream(context, it) }.getOrNull() },
        )
    }

    /** The device media is routed to; older releases fall back to priority. */
    private fun activeDevice(manager: AudioManager): AudioDeviceInfo? {
        if (Build.VERSION.SDK_INT >= 33) {
            manager.getAudioDevicesForAttributes(media).firstOrNull()?.let { routed ->
                return manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                    .firstOrNull { it.type == routed.type && it.address == routed.address }
                    ?: manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).firstOrNull { it.type == routed.type }
            }
        }
        val outputs = manager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        val priority = listOf(
            AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET,
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
            AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        )
        return priority.firstNotNullOfOrNull { type -> outputs.firstOrNull { it.type == type } }
    }

    private fun describe(manager: AudioManager, device: AudioDeviceInfo): Map<String, Any?> {
        val values = mutableMapOf<String, Any?>(
            "type" to typeName(device.type),
            "name" to device.productName?.toString()?.trim().orEmpty(),
            "sampleRates" to device.sampleRates.toList().distinct().sorted(),
            "bitDepths" to device.encodings.toList().mapNotNull { bits(it) }.distinct().sorted(),
            "float" to device.encodings.contains(AudioFormat.ENCODING_PCM_FLOAT),
            "channelCounts" to device.channelCounts.toList().distinct().sorted(),
        )
        if (Build.VERSION.SDK_INT >= 34) {
            val supported = runCatching { manager.getSupportedMixerAttributes(device) }.getOrDefault(emptyList())
            values["bitPerfectCapable"] = supported.any {
                it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT
            }
            runCatching { manager.getPreferredMixerAttributes(media, device) }.getOrNull()?.let {
                values["mixer"] = mapOf(
                    "sampleRate" to it.format.sampleRate,
                    "bitDepth" to bits(it.format.encoding),
                    "bitPerfect" to (it.mixerBehavior == AudioMixerAttributes.MIXER_BEHAVIOR_BIT_PERFECT),
                )
            }
        }
        return values
    }

    private fun spatializer(manager: AudioManager): Map<String, Any?>? {
        if (Build.VERSION.SDK_INT < 32) return null
        val spatializer = manager.spatializer
        return mapOf(
            "available" to spatializer.isAvailable,
            "enabled" to spatializer.isEnabled,
            "headTracking" to (Build.VERSION.SDK_INT >= 33 && spatializer.isHeadTrackerAvailable),
        )
    }

    /** What the platform extractor and decoder see for the playing file. */
    private fun stream(context: Context, path: String): Map<String, Any?>? {
        if (!path.startsWith("/") && !path.startsWith("content://")) return null
        val extractor = MediaExtractor()
        try {
            if (path.startsWith("content://")) {
                extractor.setDataSource(context, Uri.parse(path), null)
            } else {
                extractor.setDataSource(path)
            }
            val format = (0 until extractor.trackCount).map(extractor::getTrackFormat)
                .firstOrNull { it.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true }
                ?: return null
            fun int(key: String) = if (format.containsKey(key)) runCatching { format.getInteger(key) }.getOrNull() else null
            val decoder = runCatching {
                MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format)
            }.getOrNull()
            val info = decoder?.let { name ->
                MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { it.name == name }
            }
            return mapOf(
                "mime" to format.getString(MediaFormat.KEY_MIME),
                "sampleRate" to int(MediaFormat.KEY_SAMPLE_RATE),
                "channels" to int(MediaFormat.KEY_CHANNEL_COUNT),
                "bitrate" to int(MediaFormat.KEY_BIT_RATE),
                "pcmBits" to int(MediaFormat.KEY_PCM_ENCODING)?.let(::bits),
                "durationUs" to if (format.containsKey(MediaFormat.KEY_DURATION)) format.getLong(MediaFormat.KEY_DURATION) else null,
                "decoder" to decoder,
                "hardwareDecoder" to if (Build.VERSION.SDK_INT >= 29) info?.isHardwareAccelerated else null,
            )
        } finally {
            extractor.release()
        }
    }

    private fun bits(encoding: Int): Int? = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> 8
        AudioFormat.ENCODING_PCM_16BIT -> 16
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
        AudioFormat.ENCODING_PCM_32BIT, AudioFormat.ENCODING_PCM_FLOAT -> 32
        else -> null
    }

    private fun typeName(type: Int): String = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER, AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE -> "speaker"
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "earpiece"
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired_headphones"
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "wired_headset"
        AudioDeviceInfo.TYPE_LINE_ANALOG, AudioDeviceInfo.TYPE_AUX_LINE -> "line"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP -> "bluetooth"
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_BLE_BROADCAST -> "bluetooth_le"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb_headset"
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC, AudioDeviceInfo.TYPE_HDMI_EARC -> "hdmi"
        AudioDeviceInfo.TYPE_DOCK -> "dock"
        AudioDeviceInfo.TYPE_REMOTE_SUBMIX -> "cast"
        AudioDeviceInfo.TYPE_HEARING_AID -> "hearing_aid"
        else -> "other"
    }
}
