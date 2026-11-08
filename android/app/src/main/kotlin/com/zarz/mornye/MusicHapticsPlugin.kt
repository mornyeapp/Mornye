package com.zarz.mornye

import android.content.Context
import android.media.AudioAttributes
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/** Renders one music pulse at a time; Dart owns timing against playback. */
class MusicHapticsPlugin : FlutterPlugin {
    private lateinit var channel: MethodChannel
    private var vibrator: Vibrator? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        vibrator = if (Build.VERSION.SDK_INT >= 31) {
            context.getSystemService(VibratorManager::class.java)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        channel = MethodChannel(binding.binaryMessenger, "com.zarz.mornye/haptics")
        channel.setMethodCallHandler { call, result ->
            if (call.method != "pulse") return@setMethodCallHandler result.notImplemented()
            runCatching {
                pulse(
                    (call.argument<Double>("intensity") ?: 0.0).coerceIn(0.0, 1.0),
                    (call.argument<Double>("sharpness") ?: 0.0).coerceIn(0.0, 1.0),
                    touch = call.argument<String>("usage") == "touch",
                )
            }
            result.success(null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        vibrator?.cancel()
        vibrator = null
    }

    /**
     * Music pulses answer to media vibration. [touch] pulses are UI feedback
     * (a swipe's ticks) and answer to the touch feedback setting instead.
     */
    private fun pulse(intensity: Double, sharpness: Double, touch: Boolean) {
        val vibrator = vibrator ?: return
        if (Build.VERSION.SDK_INT < 26 || !vibrator.hasVibrator() || intensity <= 0) return
        // Without tuned primitives the motor is often an eccentric mass that
        // needs tens of milliseconds to spin up, and stays still at low
        // amplitudes. Shorter or weaker one-shots are not felt at all.
        val effect = composed(vibrator, intensity, sharpness)
            ?: if (vibrator.hasAmplitudeControl()) {
                // Bass hits are longer and softer; bright hits short and crisp.
                VibrationEffect.createOneShot(
                    (20 + 20 * (1 - sharpness)).toLong(),
                    (MIN_AMPLITUDE + (255 - MIN_AMPLITUDE) * intensity).toInt()
                        .coerceIn(MIN_AMPLITUDE, 255),
                )
            } else if (intensity >= 0.35) {
                // On/off motors cannot vary strength; accents last longer.
                VibrationEffect.createOneShot(
                    (25 + 25 * intensity).toLong(),
                    VibrationEffect.DEFAULT_AMPLITUDE,
                )
            } else {
                return
            }
        // Media usage honours the system's separate media vibration switch;
        // touch usage honours the touch feedback switch.
        if (Build.VERSION.SDK_INT >= 33) {
            vibrator.vibrate(
                effect,
                VibrationAttributes.createForUsage(
                    if (touch) VibrationAttributes.USAGE_TOUCH else VibrationAttributes.USAGE_MEDIA,
                ),
            )
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(
                effect,
                AudioAttributes.Builder()
                    .setUsage(
                        if (touch) {
                            AudioAttributes.USAGE_ASSISTANCE_SONIFICATION
                        } else {
                            AudioAttributes.USAGE_MEDIA
                        },
                    )
                    .setContentType(
                        if (touch) {
                            AudioAttributes.CONTENT_TYPE_SONIFICATION
                        } else {
                            AudioAttributes.CONTENT_TYPE_MUSIC
                        },
                    )
                    .build(),
            )
        }
    }

    /** Device-tuned primitives feel cleaner than raw motor amplitudes. */
    private fun composed(vibrator: Vibrator, intensity: Double, sharpness: Double): VibrationEffect? {
        if (Build.VERSION.SDK_INT < 31) return null
        val primitive = if (sharpness < 0.5) {
            VibrationEffect.Composition.PRIMITIVE_THUD
        } else {
            VibrationEffect.Composition.PRIMITIVE_CLICK
        }
        if (!vibrator.areAllPrimitivesSupported(primitive)) return null
        return VibrationEffect.startComposition()
            .addPrimitive(primitive, intensity.toFloat())
            .compose()
    }

    private companion object {
        /** The lowest amplitude that reliably moves an eccentric mass motor. */
        const val MIN_AMPLITUDE = 70
    }
}
