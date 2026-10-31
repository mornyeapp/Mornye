package com.antonkarpenko.ffmpegkit;

import static com.antonkarpenko.ffmpegkit.PluginTestSupport.FFMPEG_KIT_TAG;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.LOADING_MESSAGE;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.globalCallbacksRegistered;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.mainThread;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.runOnMain;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.start;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import android.util.Log;

import com.antonkarpenko.ffmpegkit.PluginTestSupport.Messenger;
import com.antonkarpenko.ffmpegkit.PluginTestSupport.Reply;

import org.junit.BeforeClass;
import org.junit.Test;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

import io.flutter.plugin.common.MethodCall;

// FFmpegKitConfig initializes once per JVM; the Gradle test task forks one per test class.
public class FFmpegKitFlutterPluginDirectCallerTest {

    @BeforeClass
    public static void enableTestMode() {
        PluginTestSupport.enableTestMode();
    }

    @Test(timeout = 30000)
    public void aCallbackWrappedBeforeTheFirstMethodCallIsKept() throws Exception {
        final AtomicInteger loads = new AtomicInteger();
        Log.listener = (priority, tag, msg, tr) -> {
            if (FFMPEG_KIT_TAG.equals(tag) && LOADING_MESSAGE.equals(msg)) {
                loads.incrementAndGet();
            }
        };
        try {
            final FFmpegKitFlutterPlugin engine = new FFmpegKitFlutterPlugin();
            assertTrue(runOnMain(() -> engine.init(new Messenger(), null), 2000));

            final CountDownLatch wrapped = new CountDownLatch(1);
            final AtomicBoolean registeredBeforeWrapping = new AtomicBoolean();
            final FFmpegSessionCompleteCallback wrapper = session -> {
            };
            start("worker", () -> {
                FFmpegKitFlutterPlugin.ensureGlobalCallbacksRegistered();
                registeredBeforeWrapping.set(globalCallbacksRegistered());
                FFmpegKitConfig.enableFFmpegSessionCompleteCallback(wrapper);
                wrapped.countDown();
            });
            assertTrue(wrapped.await(5, TimeUnit.SECONDS));
            assertTrue("the callbacks are registered when the direct caller returns", registeredBeforeWrapping.get());

            final Reply platform = new Reply(false);
            assertTrue(runOnMain(() -> engine.onMethodCall(new MethodCall("getPlatform", null), platform), 2000));
            assertTrue(platform.await(5000));

            assertEquals("success", platform.kind);
            assertSame(mainThread(), platform.thread);
            assertSame("the first method call does not replace the wrapper",
                    wrapper, FFmpegKitConfig.getFFmpegSessionCompleteCallback());
            assertEquals(1, loads.get());
        } finally {
            Log.listener = null;
        }
    }
}
