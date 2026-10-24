package xyz.luan.audioplayers;

import android.content.Context;
import android.media.AudioManager;
import android.os.SystemClock;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.HashMap;
import java.util.Map;

import org.junit.Test;
import org.junit.runner.RunWith;

import xyz.luan.audioplayers.player.SoundPoolManager;
import xyz.luan.audioplayers.player.WrappedPlayer;

import static org.junit.Assert.assertEquals;

@SuppressWarnings("deprecation")
@RunWith(AndroidJUnit4.class)
public class AudioContextRoutingTest {
    private static final BinaryMessenger MESSENGER = new BinaryMessenger() {
        @Override public void send(String channel, ByteBuffer message) {}
        @Override public void send(String channel, ByteBuffer message, BinaryReply callback) {
            if (callback != null) callback.reply(null);
        }
        @Override public void setMessageHandler(String channel, BinaryMessageHandler handler) {}
    };

    @Test
    public void globalMusicContextPreservesAnExistingCommunicationRoute() {
        onAudioThread((plugin, manager) -> {
            manager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            manager.setSpeakerphoneOn(true);
            assertEquals(AudioManager.MODE_IN_COMMUNICATION, manager.getMode());
            awaitSpeakerphone(manager, true);

            setGlobalContext(plugin, new AudioContextAndroid());

            assertEquals(AudioManager.MODE_IN_COMMUNICATION, manager.getMode());
            awaitSpeakerphone(manager, true);
        });
    }

    @Test
    public void configuringAnIdleMusicPlayerPreservesTheSystemRoute() {
        onAudioThread((plugin, manager) -> {
            manager.setMode(AudioManager.MODE_IN_COMMUNICATION);
            manager.setSpeakerphoneOn(true);
            assertEquals(AudioManager.MODE_IN_COMMUNICATION, manager.getMode());
            awaitSpeakerphone(manager, true);
            EventHandler events = new EventHandler(new EventChannel(MESSENGER, "routing-test"));
            WrappedPlayer player = new WrappedPlayer(
                    plugin, events, new AudioContextAndroid(), new SoundPoolManager(plugin));
            try {
                player.updateAudioContext(new AudioContextAndroid(
                        false, true, android.media.AudioAttributes.CONTENT_TYPE_MUSIC,
                        android.media.AudioAttributes.USAGE_MEDIA, AudioManager.AUDIOFOCUS_NONE,
                        AudioManager.MODE_NORMAL));

                assertEquals(AudioManager.MODE_IN_COMMUNICATION, manager.getMode());
                awaitSpeakerphone(manager, true);
            } finally {
                player.dispose();
            }
        });
    }

    @Test
    public void explicitGlobalRoutingChangesApplyTheRequestedContext() {
        onAudioThread((plugin, manager) -> {
            manager.setMode(AudioManager.MODE_NORMAL);
            manager.setSpeakerphoneOn(false);
            AudioContextAndroid communication = new AudioContextAndroid(
                    true, false, android.media.AudioAttributes.CONTENT_TYPE_SPEECH,
                    android.media.AudioAttributes.USAGE_VOICE_COMMUNICATION,
                    AudioManager.AUDIOFOCUS_NONE, AudioManager.MODE_IN_COMMUNICATION);

            setGlobalContext(plugin, communication);
            assertEquals(AudioManager.MODE_IN_COMMUNICATION, manager.getMode());
            awaitSpeakerphone(manager, true);

            setGlobalContext(plugin, new AudioContextAndroid());
            assertEquals(AudioManager.MODE_NORMAL, manager.getMode());
            awaitSpeakerphone(manager, false);
        });
    }

    private interface AudioCheck {
        void run(AudioplayersPlugin plugin, AudioManager manager) throws Exception;
    }

    private static void awaitSpeakerphone(AudioManager manager, boolean expected) {
        long deadline = SystemClock.uptimeMillis() + 2000;
        while (manager.isSpeakerphoneOn() != expected && SystemClock.uptimeMillis() < deadline) {
            SystemClock.sleep(10);
        }
        assertEquals(expected, manager.isSpeakerphoneOn());
    }

    private static void onAudioThread(AudioCheck check) {
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
            AudioManager manager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
            int originalMode = manager.getMode();
            boolean originalSpeaker = manager.isSpeakerphoneOn();
            try {
                AudioplayersPlugin plugin = new AudioplayersPlugin();
                Field field = AudioplayersPlugin.class.getDeclaredField("context");
                field.setAccessible(true);
                field.set(plugin, context);
                check.run(plugin, manager);
            } catch (Exception error) {
                throw new AssertionError(error);
            } finally {
                manager.setMode(originalMode);
                manager.setSpeakerphoneOn(originalSpeaker);
                awaitSpeakerphone(manager, originalSpeaker);
            }
        });
    }

    private static void setGlobalContext(AudioplayersPlugin plugin, AudioContextAndroid context) throws Exception {
        Map<String, Object> arguments = new HashMap<>();
        arguments.put("isSpeakerphoneOn", context.isSpeakerphoneOn());
        arguments.put("stayAwake", context.getStayAwake());
        arguments.put("contentType", context.getContentType());
        arguments.put("usageType", context.getUsageType());
        arguments.put("audioFocus", context.getAudioFocus());
        arguments.put("audioMode", context.getAudioMode());
        Method method = AudioplayersPlugin.class.getDeclaredMethod(
                "globalMethodHandler", MethodCall.class, MethodChannel.Result.class);
        method.setAccessible(true);
        method.invoke(plugin, new MethodCall("setAudioContext", arguments), new MethodChannel.Result() {
            @Override public void success(Object result) { assertEquals(1, result); }
            @Override public void error(String code, String message, Object details) { throw new AssertionError(message); }
            @Override public void notImplemented() { throw new AssertionError("Missing context handler"); }
        });
    }
}
