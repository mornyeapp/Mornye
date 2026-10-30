package com.antonkarpenko.ffmpegkit;

import static com.antonkarpenko.ffmpegkit.PluginTestSupport.FFMPEG_KIT_TAG;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.LOADING_MESSAGE;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.awaitUninterruptibly;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.start;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertTrue;

import android.util.Log;

import com.antonkarpenko.ffmpegkit.PluginTestSupport.Messenger;
import com.antonkarpenko.ffmpegkit.PluginTestSupport.Reply;

import org.junit.BeforeClass;
import org.junit.Test;

import java.util.Collections;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import io.flutter.plugin.common.MethodCall;

// FFmpegKitConfig initializes once per JVM; the Gradle test task forks one per test class.
public class FFmpegKitFlutterPluginStartupTest {

    @BeforeClass
    public static void enableTestMode() {
        PluginTestSupport.enableTestMode();
    }

    @Test(timeout = 30000)
    public void firstCallLoadsFFmpegKitInTheBackgroundAndCallsWaitInOrder() throws Exception {
        final CountDownLatch loading = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);
        final AtomicReference<Thread> loader = new AtomicReference<>();
        final AtomicInteger loads = new AtomicInteger();
        final List<String> failedCallLogs = new CopyOnWriteArrayList<>();
        Log.listener = (priority, tag, msg, tr) -> {
            if (FFMPEG_KIT_TAG.equals(tag) && LOADING_MESSAGE.equals(msg)) {
                loads.incrementAndGet();
                loader.set(Thread.currentThread());
                loading.countDown();
                awaitUninterruptibly(release);
            } else if (priority == Log.ERROR && "Failed to handle method call".equals(msg)) {
                failedCallLogs.add(tag);
            }
        };
        try {
            final FFmpegKitFlutterPlugin engine = new FFmpegKitFlutterPlugin();
            final Thread attach = start("attach", () -> engine.init(new Messenger(), null));
            attach.join(2000);
            assertFalse("attach returned", attach.isAlive());
            final FFmpegKitFlutterPlugin backgroundEngine = new FFmpegKitFlutterPlugin();
            backgroundEngine.init(new Messenger(), null);
            assertFalse("attach does not load FFmpegKit", loading.await(300, TimeUnit.MILLISECONDS));

            final Reply logLevel = new Reply(true);
            final Thread call = start("call", () -> engine.onMethodCall(new MethodCall("getLogLevel", null), logLevel));
            assertTrue("the first call starts the load", loading.await(5, TimeUnit.SECONDS));
            call.join(2000);
            assertFalse("the calling thread does not wait for the load", call.isAlive());
            assertNotSame(call, loader.get());

            final Reply platform = new Reply(true);
            backgroundEngine.onMethodCall(new MethodCall("getPlatform", null), platform);
            final Reply badArgument = new Reply(false);
            engine.onMethodCall(new MethodCall("getSession",
                    Collections.singletonMap(FFmpegKitFlutterPlugin.ARGUMENT_SESSION_ID, "not a number")), badArgument);
            assertFalse("a call during the load waits for it", logLevel.await(300));
            assertFalse("a call from another engine waits for it too", platform.await(0));
            assertFalse(badArgument.await(0));

            release.countDown();
            assertTrue(logLevel.await(5000));
            assertTrue(platform.await(5000));
            assertTrue(badArgument.await(5000));

            final Reply logLevelAfterLoad = new Reply(true);
            engine.onMethodCall(new MethodCall("getLogLevel", null), logLevelAfterLoad);
            assertTrue(logLevelAfterLoad.await(5000));

            assertEquals("success", logLevel.kind);
            assertNotNull(logLevel.value);
            assertEquals(logLevelAfterLoad.value, logLevel.value);
            assertEquals("success", platform.kind);
            assertEquals(FFmpegKitFlutterPlugin.PLATFORM_NAME, platform.value);
            assertTrue("callbacks were registered before the reply", logLevel.callbacksRegisteredAtReply);
            assertTrue("callbacks were registered before the reply", platform.callbacksRegisteredAtReply);
            assertEquals("error", badArgument.kind);
            assertEquals("error", badArgument.value);
            assertEquals(Collections.singletonList("MethodChannel#flutter.arthenica.com/ffmpeg_kit"), failedCallLogs);
            assertTrue("waiting calls run in arrival order",
                    logLevel.order < platform.order && platform.order < badArgument.order);
            assertEquals(1, loads.get());
        } finally {
            release.countDown();
            Log.listener = null;
        }
    }
}
