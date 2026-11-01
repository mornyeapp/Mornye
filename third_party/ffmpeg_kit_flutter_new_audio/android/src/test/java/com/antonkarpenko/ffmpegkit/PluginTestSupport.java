package com.antonkarpenko.ffmpegkit;

import android.os.Handler;
import android.os.Looper;

import java.lang.reflect.Field;
import java.nio.ByteBuffer;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

final class PluginTestSupport {

    static final String FFMPEG_KIT_TAG = "ffmpeg-kit";
    static final String LOADING_MESSAGE = "Loading ffmpeg-kit.";

    private PluginTestSupport() {
    }

    static void enableTestMode() {
        // NativeLoader skips System.loadLibrary in this mode; the static initializer still runs.
        System.setProperty("enable.ffmpeg.kit.test.mode", "true");
    }

    static Thread mainThread() {
        return Looper.getMainLooper().getThread();
    }

    /** Runs the work on the main thread, where the platform delivers method calls. */
    static boolean runOnMain(final Runnable runnable, final long millis) throws InterruptedException {
        final CountDownLatch done = new CountDownLatch(1);
        new Handler(Looper.getMainLooper()).post(() -> {
            runnable.run();
            done.countDown();
        });
        return done.await(millis, TimeUnit.MILLISECONDS);
    }

    static Thread start(final String name, final Runnable runnable) {
        final Thread thread = new Thread(runnable, name);
        thread.setDaemon(true);
        thread.start();
        return thread;
    }

    static void awaitUninterruptibly(final CountDownLatch latch) {
        boolean interrupted = false;
        while (true) {
            try {
                latch.await();
                break;
            } catch (final InterruptedException e) {
                interrupted = true;
            }
        }
        if (interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    static boolean globalCallbacksRegistered() {
        return FFmpegKitConfig.getFFmpegSessionCompleteCallback() != null
                && FFmpegKitConfig.getFFprobeSessionCompleteCallback() != null
                && FFmpegKitConfig.getMediaInformationSessionCompleteCallback() != null
                && staticField("globalLogCallback") != null
                && staticField("globalStatisticsCallback") != null;
    }

    private static Object staticField(final String name) {
        try {
            final Field field = FFmpegKitConfig.class.getDeclaredField(name);
            field.setAccessible(true);
            return field.get(null);
        } catch (final ReflectiveOperationException e) {
            throw new AssertionError(e);
        }
    }

    static final class Messenger implements BinaryMessenger {

        @Override
        public void send(final String channel, final ByteBuffer message) {
        }

        @Override
        public void send(final String channel, final ByteBuffer message, final BinaryReply callback) {
        }

        @Override
        public void setMessageHandler(final String channel, final BinaryMessageHandler handler) {
        }
    }

    static final class Reply implements MethodChannel.Result {

        private static final AtomicInteger replies = new AtomicInteger();

        private final boolean observeCallbacks;
        private final CountDownLatch done = new CountDownLatch(1);
        volatile String kind;
        volatile Object value;
        volatile int order;
        volatile Thread thread;
        volatile boolean callbacksRegisteredAtReply;

        Reply(final boolean observeCallbacks) {
            this.observeCallbacks = observeCallbacks;
        }

        boolean await(final long millis) throws InterruptedException {
            return done.await(millis, TimeUnit.MILLISECONDS);
        }

        @Override
        public void success(final Object result) {
            record("success", result);
        }

        @Override
        public void error(final String errorCode, final String errorMessage, final Object errorDetails) {
            record("error", errorCode);
        }

        @Override
        public void notImplemented() {
            record("notImplemented", null);
        }

        private void record(final String kind, final Object value) {
            if (observeCallbacks) {
                callbacksRegisteredAtReply = globalCallbacksRegistered();
            }
            this.kind = kind;
            this.value = value;
            this.thread = Thread.currentThread();
            this.order = replies.incrementAndGet();
            done.countDown();
        }
    }
}
