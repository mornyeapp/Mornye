package com.ryanheise.audioservice;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.os.SystemClock;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import java.lang.ref.WeakReference;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;

import io.flutter.plugin.common.BinaryMessenger;

import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

@RunWith(AndroidJUnit4.class)
public class AudioServiceLifecycleTest {
    @Test
    public void playbackLeaseRenewsAcrossTimeoutsAndStopsAfterRelease() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        PowerManager power = (PowerManager) instrumentation.getTargetContext().getSystemService(Context.POWER_SERVICE);
        PowerManager.WakeLock lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "mornye:lease-test");
        PlaybackWakeLock lease = new PlaybackWakeLock(lock, new Handler(Looper.getMainLooper()), 1000, 100);
        try {
            instrumentation.runOnMainSync(lease::acquire);
            SystemClock.sleep(2200);
            assertTrue("Long playback must keep the CPU awake across lease expiry", lock.isHeld());
            instrumentation.runOnMainSync(() -> {
                lease.acquire();
                lease.acquire();
                lease.release();
            });
            SystemClock.sleep(300);
            assertFalse("Pause must cancel renewal and release repeated acquisitions", lock.isHeld());
        } finally {
            instrumentation.runOnMainSync(lease::release);
        }
    }

    @Test
    public void abandonedPlaybackLeaseExpiresWithoutRenewal() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        PowerManager power = (PowerManager) instrumentation.getTargetContext().getSystemService(Context.POWER_SERVICE);
        PowerManager.WakeLock lock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "mornye:lease-expiry-test");
        Handler handler = new Handler(Looper.getMainLooper());
        PlaybackWakeLock lease = new PlaybackWakeLock(lock, handler, 500, 100);
        try {
            instrumentation.runOnMainSync(() -> {
                lease.acquire();
                handler.removeCallbacksAndMessages(null);
            });
            SystemClock.sleep(1000);
            assertFalse("An abandoned lease must not hold the CPU indefinitely", lock.isHeld());
        } finally {
            instrumentation.runOnMainSync(lease::release);
        }
    }

    @Test
    public void everyNotificationIconResolvesToACompiledResource() {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        String[] resources = {
            "mipmap/ic_launcher", "drawable/ic_launcher_monochrome",
            "drawable/ic_notification_mornye",
            "drawable/ic_notification_airplay", "drawable/ic_notification_star",
            "drawable/ic_notification_star_filled", "drawable/ic_notification_shuffle",
            "drawable/ic_notification_shuffle_on", "drawable/ic_widget_previous",
            "drawable/ic_widget_next", "drawable/ic_widget_play", "drawable/ic_widget_pause",
            "drawable/audio_service_stop", "drawable/audio_service_pause",
            "drawable/audio_service_play_arrow", "drawable/audio_service_fast_rewind",
            "drawable/audio_service_skip_next", "drawable/audio_service_skip_previous",
            "drawable/audio_service_fast_forward",
        };
        for (String resource : resources) {
            int id = AudioServicePlugin.resolveResourceId(context, resource);
            assertTrue(resource, id != 0);
            assertEquals(resource.substring(resource.indexOf('/') + 1), context.getResources().getResourceEntryName(id));
        }
        assertEquals(0, AudioServicePlugin.resolveResourceId(context, "drawable/missing_icon"));
        assertEquals(0, AudioServicePlugin.resolveResourceId(context, null));
    }

    @Test
    public void notificationMarkFillsTheStatusBarGridWithoutClipping() {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        int id = AudioServicePlugin.resolveResourceId(context, "drawable/ic_notification_mornye");
        for (int size : new int[] {24, 36, 48, 72, 96}) {
            Drawable drawable = context.getDrawable(id);
            Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
            drawable.setBounds(0, 0, size, size);
            drawable.draw(new Canvas(bitmap));
            Rect opaque = new Rect();
            for (int y = 0; y < size; y++) {
                for (int x = 0; x < size; x++) {
                    if (Color.alpha(bitmap.getPixel(x, y)) > 127) {
                        opaque.union(x, y, x + 1, y + 1);
                    }
                }
            }
            bitmap.recycle();
            assertTrue("Visible width at " + size + "px: " + opaque, opaque.width() >= size * 0.58);
            assertTrue("Visible height at " + size + "px: " + opaque, opaque.height() >= size * 0.78);
            assertTrue("Left inset at " + size + "px", opaque.left >= size * 0.05);
            assertTrue("Top inset at " + size + "px", opaque.top >= size * 0.05);
            assertTrue("Right inset at " + size + "px", opaque.right <= size * 0.95);
            assertTrue("Bottom inset at " + size + "px", opaque.bottom <= size * 0.95);
            assertEquals(size / 2f, opaque.exactCenterX(), 1f);
            assertEquals(size / 2f, opaque.exactCenterY(), 1f);
        }
    }

    private static class DeepLinkActivity extends AudioServiceFragmentActivity {
        Bundle metadata;
        boolean missing;

        @Override
        protected Bundle getMetaData() throws PackageManager.NameNotFoundException {
            if (missing) throw new PackageManager.NameNotFoundException();
            return metadata;
        }
    }

    @Test
    public void deepLinkPolicyPreservesManifestDefaultsAndOverrides() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        instrumentation.runOnMainSync(() -> {
            DeepLinkActivity activity = new DeepLinkActivity();
            assertTrue(activity.shouldHandleDeeplinking());
            activity.metadata = new Bundle();
            assertTrue(activity.shouldHandleDeeplinking());
            activity.metadata.putBoolean("flutter_deeplinking_enabled", false);
            assertFalse(activity.shouldHandleDeeplinking());
            activity.metadata.putBoolean("flutter_deeplinking_enabled", true);
            assertTrue(activity.shouldHandleDeeplinking());
            activity.missing = true;
            assertFalse(activity.shouldHandleDeeplinking());
        });
    }

    private static class AttachedActivity extends Activity {
        AttachedActivity(Context context) {
            attachBaseContext(context);
        }
    }

    private static class NoopMessenger implements BinaryMessenger {
        @Override
        public void send(String channel, ByteBuffer message) {}

        @Override
        public void send(String channel, ByteBuffer message, BinaryReply reply) {}

        @Override
        public void setMessageHandler(String channel, BinaryMessageHandler handler) {}
    }

    @Test
    public void clientKeepsOnlyApplicationContextAndClearsOnEngineDetach() {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        instrumentation.runOnMainSync(() -> {
            try {
                Class<?> type = Class.forName(AudioServicePlugin.class.getName() + "$ClientInterface");
                Constructor<?> constructor = type.getDeclaredConstructor(BinaryMessenger.class);
                constructor.setAccessible(true);
                Object client = constructor.newInstance(new NoopMessenger());
                Method setContext = type.getDeclaredMethod("setContext", Context.class);
                Method setActivity = type.getDeclaredMethod("setActivity", Activity.class);
                Method getActivity = type.getDeclaredMethod("getActivity");
                setContext.setAccessible(true);
                setActivity.setAccessible(true);
                getActivity.setAccessible(true);
                Activity activity = new AttachedActivity(instrumentation.getTargetContext());
                setContext.invoke(client, activity);
                setActivity.invoke(client, activity);
                Field contextField = type.getDeclaredField("context");
                Field activityField = type.getDeclaredField("activity");
                contextField.setAccessible(true);
                activityField.setAccessible(true);
                assertSame(activity.getApplicationContext(), contextField.get(client));
                assertTrue(activityField.get(client) instanceof WeakReference);
                assertSame(activity, getActivity.invoke(client));

                AudioServicePlugin plugin = new AudioServicePlugin();
                Field clientField = AudioServicePlugin.class.getDeclaredField("clientInterface");
                Field mainField = AudioServicePlugin.class.getDeclaredField("mainClientInterface");
                clientField.setAccessible(true);
                mainField.setAccessible(true);
                clientField.set(plugin, client);
                mainField.set(null, client);
                plugin.onDetachedFromEngine(null);
                assertNull(contextField.get(client));
                assertNull(getActivity.invoke(client));
                assertNull(clientField.get(plugin));
                assertNull(mainField.get(null));
            } catch (ReflectiveOperationException error) {
                throw new AssertionError(error);
            }
        });
    }
}
