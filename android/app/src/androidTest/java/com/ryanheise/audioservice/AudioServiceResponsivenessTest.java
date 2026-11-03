package com.ryanheise.audioservice;

import android.app.Instrumentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.support.v4.media.MediaDescriptionCompat;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import java.lang.reflect.Field;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.FutureTask;
import java.util.concurrent.TimeUnit;

import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

@RunWith(AndroidJUnit4.class)
public class AudioServiceResponsivenessTest {
    @Test
    public void queueInsertionDoesNotWaitForSlowArtwork() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        SlowArtworkService[] services = new SlowArtworkService[1];
        instrumentation.runOnMainSync(() -> services[0] = new SlowArtworkService());
        SlowArtworkService service = services[0];
        Field queue = field("queue");
        Object previousQueue = queue.get(null);
        ExecutorService worker = Executors.newSingleThreadExecutor();
        Future<?> loading = null;
        try {
            queue.set(null, Collections.singletonList(queueItem(400)));
            MediaMetadataCompat metadata = new MediaMetadataCompat.Builder()
                    .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, "slow-cover")
                    .putString("artCacheFile", "/slow-cover.png")
                    .build();
            loading = worker.submit(() -> service.setMetadata(metadata));
            assertTrue("Artwork worker did not start", service.reading.await(2, TimeUnit.SECONDS));
            FutureTask<Integer> insertion = new FutureTask<>(() -> service.queueIndexForPosition(1));
            new Handler(Looper.getMainLooper()).post(insertion);
            assertEquals("Main-thread queue commands must not wait for artwork I/O",
                    Integer.valueOf(401), insertion.get(1, TimeUnit.SECONDS));
        } finally {
            service.release.countDown();
            if (loading != null) loading.get(2, TimeUnit.SECONDS);
            worker.shutdownNow();
            instrumentation.waitForIdleSync();
            queue.set(null, previousQueue);
        }
    }

    @Test
    public void positionUpdatesReuseTransportAndCustomActions() throws Exception {
        withService((service, session) -> {
            update(service, controls("Favorite"), new int[] {0}, 0);
            for (int i = 1; i <= 100; i++) {
                update(service, controls("Favorite"), new int[] {0}, i);
            }
            assertEquals("Unchanged controls must not rebuild PendingIntents", 2, service.preparedControls);
            assertEquals(100L, session.getController().getPlaybackState().getPosition());
            assertEquals("Favorite", session.getController().getPlaybackState()
                    .getCustomActions().get(0).getName().toString());
        });
    }

    @Test
    public void changedControlsAndConfigurationRebuildActions() throws Exception {
        withService((service, session) -> {
            List<MediaControl> controls = new ArrayList<>(controls("Favorite"));
            update(service, controls, new int[] {0}, 0);
            // A caller may reuse and mutate its list; the published controls
            // must retain a separate snapshot for the next comparison.
            controls.set(1, controls("Unfavorite").get(1));
            update(service, controls, new int[] {0}, 1);
            assertEquals(4, service.preparedControls);
            assertEquals("Unfavorite", session.getController().getPlaybackState()
                    .getCustomActions().get(0).getName().toString());
            update(service, controls, new int[] {1}, 2);
            assertEquals("Compact layout changes reuse the actions", 4, service.preparedControls);
            AudioServiceConfig config = new AudioServiceConfig(service.getApplicationContext());
            config.androidNotificationChannelId = "responsiveness-test";
            config.activityClassName = null;
            service.configure(config);
            update(service, controls, new int[] {1}, 3);
            assertEquals("Configuration changes must invalidate PendingIntents", 6, service.preparedControls);
        });
    }

    @Test
    public void queuePublicationKeepsAnIndependentSnapshot() throws Exception {
        Field queue = field("queue");
        Object previousQueue = queue.get(null);
        try {
            withService((service, session) -> {
                List<MediaSessionCompat.QueueItem> items = new ArrayList<>();
                items.add(queueItem(400));
                service.setQueue(items, Collections.emptyMap());
                items.clear();
                assertEquals(401, service.queueIndexForPosition(1));
            });
        } finally {
            queue.set(null, previousQueue);
        }
    }

    private static void update(AudioService service, List<MediaControl> controls, int[] compact, long position) {
        service.setState(controls, 0, compact, AudioProcessingState.ready, false,
                position, 0, 1f, SystemClock.elapsedRealtime(), null, null, 0, 0, false, 0L);
    }

    private static List<MediaControl> controls(String label) {
        return Arrays.asList(
                new MediaControl("drawable/play", "Play", PlaybackStateCompat.ACTION_PLAY, null),
                new MediaControl("drawable/favorite", label, 0,
                        new CustomMediaAction("favorite", Collections.singletonMap("label", label))));
    }

    private static MediaSessionCompat.QueueItem queueItem(long index) {
        return new MediaSessionCompat.QueueItem(new MediaDescriptionCompat.Builder()
                .setMediaId("song-" + index).build(), index);
    }

    private interface SessionCheck {
        void run(CountingService service, MediaSessionCompat session) throws Exception;
    }

    private static void withService(SessionCheck check) throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        instrumentation.runOnMainSync(() -> {
            CountingService service = new CountingService(instrumentation.getTargetContext());
            MediaSessionCompat session = new MediaSessionCompat(
                    instrumentation.getTargetContext(), "responsiveness-test");
            try {
                field("mediaSession").set(service, session);
                check.run(service, session);
            } catch (Exception error) {
                throw new AssertionError(error);
            } finally {
                session.release();
            }
        });
    }

    private static Field field(String name) throws Exception {
        Field field = AudioService.class.getDeclaredField(name);
        field.setAccessible(true);
        return field;
    }

    private static class CountingService extends AudioService {
        int preparedControls;

        CountingService(Context context) {
            attachBaseContext(context);
        }

        @Override
        int getResourceId(String resource) {
            return android.R.drawable.ic_media_play;
        }

        @Override
        PlaybackStateCompat.CustomAction createCustomAction(MediaControl control) {
            preparedControls++;
            return super.createCustomAction(control);
        }
    }

    private static class SlowArtworkService extends AudioService {
        final CountDownLatch reading = new CountDownLatch(1);
        final CountDownLatch release = new CountDownLatch(1);

        @Override
        Bitmap loadArtBitmap(String path, String thumbnail) {
            reading.countDown();
            try {
                if (!release.await(5, TimeUnit.SECONDS)) throw new AssertionError("Artwork read was not released");
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                throw new AssertionError(error);
            }
            return null;
        }
    }
}
