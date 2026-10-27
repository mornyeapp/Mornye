package com.zarz.mornye

import android.media.MediaPlayer
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioplayersPlugin
import xyz.luan.audioplayers.EventHandler
import xyz.luan.audioplayers.player.MediaPlayerWrapper
import xyz.luan.audioplayers.player.SoundPoolManager
import xyz.luan.audioplayers.player.WrappedPlayer

@RunWith(AndroidJUnit4::class)
class RetiredAudioCallbacksTest {
    private class CapturingPlayer : MediaPlayer() {
        var errorCallback: OnErrorListener? = null
        var preparedCallback: OnPreparedListener? = null
        var completionCallback: OnCompletionListener? = null
        var seekCallback: OnSeekCompleteListener? = null

        override fun setOnErrorListener(listener: OnErrorListener?) {
            errorCallback = listener
        }

        override fun setOnPreparedListener(listener: OnPreparedListener?) {
            preparedCallback = listener
        }

        override fun setOnCompletionListener(listener: OnCompletionListener?) {
            completionCallback = listener
        }

        override fun setOnSeekCompleteListener(listener: OnSeekCompleteListener?) {
            seekCallback = listener
        }
    }

    @Test
    fun cancelledSourceCallbacksCannotFailOrCompleteTheReplacement() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync {
            val plugin = AudioplayersPlugin()
            AudioplayersPlugin::class.java.getDeclaredField("context").apply {
                isAccessible = true
                set(plugin, instrumentation.targetContext)
            }
            val messenger = Proxy.newProxyInstance(
                BinaryMessenger::class.java.classLoader,
                arrayOf(BinaryMessenger::class.java),
            ) { _, _, _ -> null } as BinaryMessenger
            val events = mutableListOf<Any?>()
            val errors = mutableListOf<String?>()
            val handler = EventHandler(EventChannel(messenger, "test/retired-audio"))
            handler.onListen(null, object : EventChannel.EventSink {
                override fun success(event: Any?) { events.add(event) }
                override fun error(code: String?, message: String?, details: Any?) {
                    errors.add(code)
                }
                override fun endOfStream() {}
            })
            // Kotlin's internal constructor is public to the JVM, but this
            // instrumentation APK is a different Kotlin module from the plugin.
            val wrapped = WrappedPlayer::class.java.constructors.single().newInstance(
                plugin, handler, AudioContextAndroid(), SoundPoolManager(plugin),
            ) as WrappedPlayer
            val oldNative = CapturingPlayer()
            val old = MediaPlayerWrapper(wrapped, oldNative)
            val oldError = oldNative.errorCallback!!
            val oldCompletion = oldNative.completionCallback!!
            val oldSeek = oldNative.seekCallback!!
            val oldPrepared = oldNative.preparedCallback!!
            val currentNative = CapturingPlayer()
            val current = MediaPlayerWrapper(wrapped, currentNative)
            try {
                old.release()
                wrapped.prepared = true
                wrapped.playing = true
                events.clear()

                assertTrue(oldError.onError(oldNative, 1, Int.MIN_VALUE))
                oldCompletion.onCompletion(oldNative)
                oldSeek.onSeekComplete(oldNative)
                oldPrepared.onPrepared(oldNative)
                assertTrue("New source stays prepared", wrapped.prepared)
                assertTrue("New source stays playing", wrapped.playing)
                assertTrue("No stale events reach Dart", events.isEmpty())
                assertTrue("No stale error reaches Dart", errors.isEmpty())

                // A genuine error from the current native output still fails.
                assertTrue(currentNative.errorCallback!!.onError(currentNative, 1, Int.MIN_VALUE))
                assertFalse(wrapped.prepared)
                assertFalse(wrapped.playing)
                assertEquals(listOf("AndroidAudioError"), errors)
            } finally {
                current.release()
                handler.dispose()
            }
        }
    }
}
