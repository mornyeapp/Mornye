package com.antonkarpenko.ffmpegkit;

import static com.antonkarpenko.ffmpegkit.PluginTestSupport.FFMPEG_KIT_TAG;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.LOADING_MESSAGE;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.awaitUninterruptibly;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.mainThread;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.runOnMain;
import static com.antonkarpenko.ffmpegkit.PluginTestSupport.start;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertSame;
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
import java.util.concurrent.atomic.AtomicBoolean;
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
            final FFmpegKitFlutterPlugin backgroundEngine = new FFmpegKitFlutterPlugin();
            assertTrue("attach returned", runOnMain(() -> {
                engine.init(new Messenger(), null);
                backgroundEngine.init(new Messenger(), null);
            }, 2000));
            assertFalse("attach does not load FFmpegKit", loading.await(300, TimeUnit.MILLISECONDS));

            final Reply logLevel = new Reply(true);
            assertTrue("the main thread does not wait for the load",
                    runOnMain(() -> engine.onMethodCall(new MethodCall("getLogLevel", null), logLevel), 2000));
            assertTrue("the first call starts the load", loading.await(5, TimeUnit.SECONDS));
            assertNotSame(mainThread(), loader.get());

            final CountDownLatch directCallerReturned = new CountDownLatch(1);
            final AtomicBoolean registeredForDirectCaller = new AtomicBoolean();
            start("worker", () -> {
                FFmpegKitFlutterPlugin.ensureGlobalCallbacksRegistered();
                directCallerReturned.countDown();
                registeredForDirectCaller.set(PluginTestSupport.globalCallbacksRegistered());
            });

            final Reply platform = new Reply(true);
            final Reply badArgument = new Reply(false);
            assertTrue(runOnMain(() -> {
                backgroundEngine.onMethodCall(new MethodCall("getPlatform", null), platform);
                engine.onMethodCall(new MethodCall("getSession",
                        Collections.singletonMap(FFmpegKitFlutterPlugin.ARGUMENT_SESSION_ID, "not a number")), badArgument);
            }, 2000));
            assertFalse("a call during the load waits for it", logLevel.await(300));
            assertFalse("a call from another engine waits for it too", platform.await(0));
            assertFalse(badArgument.await(0));
            assertFalse("a direct caller waits for the registration in progress",
                    directCallerReturned.await(0, TimeUnit.MILLISECONDS));

            release.countDown();
            assertTrue(logLevel.await(5000));
            assertTrue(platform.await(5000));
            assertTrue(badArgument.await(5000));
            assertTrue(directCallerReturned.await(5, TimeUnit.SECONDS));

            final Reply logLevelAfterLoad = new Reply(true);
            assertTrue(runOnMain(() -> engine.onMethodCall(new MethodCall("getLogLevel", null), logLevelAfterLoad), 2000));
            assertTrue(logLevelAfterLoad.await(5000));

            assertEquals("success", logLevel.kind);
            assertNotNull(logLevel.value);
            assertEquals(logLevelAfterLoad.value, logLevel.value);
            assertEquals("success", platform.kind);
            assertEquals(FFmpegKitFlutterPlugin.PLATFORM_NAME, platform.value);
            assertTrue("callbacks were registered before the reply", logLevel.callbacksRegisteredAtReply);
            assertTrue("callbacks were registered before the reply", platform.callbacksRegisteredAtReply);
            assertTrue("the direct caller returned after the registration", registeredForDirectCaller.get());
            assertEquals("error", badArgument.kind);
            assertEquals("error", badArgument.value);
            assertEquals(Collections.singletonList("MethodChannel#flutter.arthenica.com/ffmpeg_kit"), failedCallLogs);
            // Successes are posted to the main thread; the error is sent while the call runs.
            assertTrue("waiting calls run in arrival order", logLevel.order < platform.order);
            for (final Reply reply : new Reply[]{logLevel, platform, badArgument, logLevelAfterLoad}) {
                assertSame("replies arrive on the main thread", mainThread(), reply.thread);
            }
            assertEquals(1, loads.get());
        } finally {
            release.countDown();
            Log.listener = null;
        }
    }
}
