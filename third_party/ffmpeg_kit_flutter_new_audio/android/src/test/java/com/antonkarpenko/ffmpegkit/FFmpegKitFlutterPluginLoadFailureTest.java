package com.antonkarpenko.ffmpegkit;

import static com.antonkarpenko.ffmpegkit.PluginTestSupport.FFMPEG_KIT_TAG;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.LOADING_MESSAGE;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.util.Log;

import com.antonkarpenko.ffmpegkit.PluginTestSupport.Messenger;
import com.antonkarpenko.ffmpegkit.PluginTestSupport.Reply;

import org.junit.BeforeClass;
import org.junit.Test;

import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

import io.flutter.plugin.common.MethodCall;

// FFmpegKitConfig initializes once per JVM; the Gradle test task forks one per test class.
public class FFmpegKitFlutterPluginLoadFailureTest {

    @BeforeClass
    public static void enableTestMode() {
        PluginTestSupport.enableTestMode();
    }

    @Test(timeout = 30000)
    public void failedLoadAnswersEveryCallLikeAChannelWithoutAHandler() throws Exception {
        // NativeLoader throws an Error like this one when System.loadLibrary fails.
        final Error failure = new Error("FFmpegKit failed to start on host.");
        final List<Throwable> logged = new CopyOnWriteArrayList<>();
        Log.listener = (priority, tag, msg, tr) -> {
            if (FFMPEG_KIT_TAG.equals(tag) && LOADING_MESSAGE.equals(msg)) {
                throw failure;
            }
            if (priority == Log.ERROR && FFmpegKitFlutterPlugin.LIBRARY_NAME.equals(tag)) {
                logged.add(tr);
            }
        };
        try {
            final FFmpegKitFlutterPlugin engine = new FFmpegKitFlutterPlugin();
            engine.init(new Messenger(), null);
            final FFmpegKitFlutterPlugin backgroundEngine = new FFmpegKitFlutterPlugin();
            backgroundEngine.init(new Messenger(), null);

            assertNotImplemented(engine, new MethodCall("getLogLevel", null));
            assertNotImplemented(engine, new MethodCall("getPlatform", null));
            assertNotImplemented(backgroundEngine, new MethodCall("ffmpegSession",
                    Collections.singletonMap(FFmpegKitFlutterPlugin.ARGUMENT_ARGUMENTS, Collections.singletonList("-version"))));

            assertEquals(1, logged.size());
            assertSame(failure, logged.get(0));
            try {
                FFmpegKitConfig.getLogLevel();
                fail("FFmpegKitConfig stays unusable after a failed load");
            } catch (final NoClassDefFoundError expected) {
                // Direct callers, such as the app's Kotlin finalizer, get the same error as before.
            }
        } finally {
            Log.listener = null;
        }
    }

    private static void assertNotImplemented(final FFmpegKitFlutterPlugin plugin, final MethodCall call) throws InterruptedException {
        final Reply reply = new Reply(false);
        plugin.onMethodCall(call, reply);
        assertTrue(reply.await(5000));
        assertEquals(call.method, "notImplemented", reply.kind);
    }
}
