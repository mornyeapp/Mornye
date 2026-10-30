package com.ryanheise.audioservice;

import android.app.Instrumentation;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.os.SystemClock;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaControllerCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;

import androidx.media.utils.MediaConstants;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;

import org.junit.Test;
import org.junit.runner.RunWith;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;

/** Exercises real platform session publication when artwork/metadata arrives after state. */
@RunWith(AndroidJUnit4.class)
public class MediaControlMetadataTest {
    @Test
    public void nextTrackMetadataRefreshesPlayingStateWithoutPauseResume() throws Exception {
        verifyMetadataPublication(true);
    }

    @Test
    public void lateMetadataPreservesPausedPositionAndControls() throws Exception {
        verifyMetadataPublication(false);
    }

    @Test
    public void recycledCachedArtworkIsDecodedAgain() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        File file = File.createTempFile("session-cover", ".png",
                instrumentation.getTargetContext().getCacheDir());
        Bitmap original = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
        try {
            try (FileOutputStream output = new FileOutputStream(file)) {
                original.compress(Bitmap.CompressFormat.PNG, 100, output);
            }
            AudioService service = createService(instrumentation);
            RecentArtCache<Bitmap> cache = new RecentArtCache<>(4);
            String uri = file.toURI().toString();
            cache.put(uri, original);
            original.recycle();
            setField(service, "artBitmapCache", cache);
            AudioServiceConfig config = new AudioServiceConfig(instrumentation.getTargetContext());
            config.artDownscaleWidth = config.artDownscaleHeight = 64;
            setField(service, "config", config);

            Bitmap decoded = service.loadArtBitmap(uri, null);
            assertNotNull(decoded);
            assertFalse(decoded.isRecycled());
            assertNotSame(original, decoded);
            assertEquals(32, decoded.getWidth());
            decoded.recycle();
        } finally {
            if (!original.isRecycled()) original.recycle();
            file.delete();
        }
    }

    @Test
    public void largeArtworkIsKeptAtTheSessionSize() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        File file = File.createTempFile("large-cover", ".png",
                instrumentation.getTargetContext().getCacheDir());
        // A 1000 px cover decodes at full size with a power-of-two sample size.
        Bitmap original = Bitmap.createBitmap(1000, 800, Bitmap.Config.ARGB_8888);
        original.eraseColor(Color.BLUE);
        Bitmap decoded = null;
        Bitmap album = null;
        Bitmap notification = null;
        try {
            try (FileOutputStream output = new FileOutputStream(file)) {
                original.compress(Bitmap.CompressFormat.PNG, 100, output);
            }
            AudioService service = createService(instrumentation);
            setField(service, "artBitmapCache", new RecentArtCache<Bitmap>(3));
            AudioServiceConfig config = new AudioServiceConfig(instrumentation.getTargetContext());
            config.artDownscaleWidth = config.artDownscaleHeight = 512;
            setField(service, "config", config);

            decoded = service.loadArtBitmap(file.getPath(), null);
            assertNotNull(decoded);
            assertEquals(512, decoded.getWidth());
            assertEquals(410, decoded.getHeight());
            assertEquals(Color.BLUE, decoded.getPixel(0, 0));
            assertSame(decoded, service.loadArtBitmap(file.getPath(), null));

            MediaMetadataCompat session = MediaArtwork.forSession(new MediaMetadataCompat.Builder(metadata("large", "Song"))
                    .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, decoded)
                    .build());
            album = session.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART);
            notification = MediaArtwork.copy(decoded, 256);
            assertNotNull(album);
            assertNotSame(decoded, album);
            assertEquals(512, album.getWidth());
            assertEquals(410, album.getHeight());
            assertNotNull(notification);
            assertEquals(256, notification.getWidth());
            assertFalse(decoded.isRecycled());
        } finally {
            original.recycle();
            if (decoded != null) decoded.recycle();
            if (album != null) album.recycle();
            if (notification != null) notification.recycle();
            file.delete();
        }
    }

    @Test
    public void recycledArtworkDoesNotInterruptMetadataPublication() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        AudioService service = createService(instrumentation);
        MediaSessionCompat[] sessions = new MediaSessionCompat[1];
        instrumentation.runOnMainSync(() -> sessions[0] = new MediaSessionCompat(
                instrumentation.getTargetContext(), "recycled-artwork-test"));
        MediaSessionCompat session = sessions[0];
        setField(service, "mediaSession", session);
        Bitmap recycled = Bitmap.createBitmap(1024, 1024, Bitmap.Config.ARGB_8888);
        MediaMetadataCompat metadata = new MediaMetadataCompat.Builder(metadata("recycled", "Song with bad cover"))
                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, recycled)
                .putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, recycled)
                .build();
        recycled.recycle();
        try {
            instrumentation.runOnMainSync(() -> {
                setState(service, 0, false);
                publish(service, metadata, recycled);
            });
            assertEquals("Song with bad cover", session.getController().getMetadata()
                    .getString(MediaMetadataCompat.METADATA_KEY_TITLE));
            assertNull(session.getController().getMetadata().getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART));
            PlaybackStateCompat state = session.getController().getPlaybackState();
            assertEquals(PlaybackStateCompat.STATE_PAUSED, state.getState());
            assertEquals(2345L, state.getPosition());
            assertEquals("recycled", state.getExtras().getString(MediaConstants.PLAYBACK_STATE_EXTRAS_KEY_MEDIA_ID));
        } finally {
            instrumentation.runOnMainSync(session::release);
        }
    }

    @Test
    public void sessionAndNotificationCopiesStayIndependentAndBounded() {
        Bitmap source = Bitmap.createBitmap(1024, 512, Bitmap.Config.ARGB_8888);
        source.eraseColor(Color.BLUE);
        MediaMetadataCompat original = new MediaMetadataCompat.Builder(metadata("cover", "Song"))
                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, source)
                .putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, source)
                .build();
        MediaMetadataCompat session = MediaArtwork.forSession(original);
        Bitmap album = session.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART);
        Bitmap icon = session.getBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON);
        Bitmap notification = MediaArtwork.copy(source, 256);
        try {
            assertNotNull(album);
            assertNotNull(icon);
            assertNotNull(notification);
            assertNotSame(source, album);
            assertNotSame(album, icon);
            assertEquals(512, album.getWidth());
            assertEquals(256, album.getHeight());
            assertEquals(256, notification.getWidth());
            assertEquals(128, notification.getHeight());
            album.recycle();
            notification.recycle();
            assertFalse(source.isRecycled());
            assertFalse(icon.isRecycled());
            assertEquals(Color.BLUE, icon.getPixel(0, 0));
            assertEquals(Color.BLUE, source.getPixel(0, 0));
            assertEquals("Song", session.getString(MediaMetadataCompat.METADATA_KEY_TITLE));
        } finally {
            source.recycle();
            if (album != null && !album.isRecycled()) album.recycle();
            if (icon != null) icon.recycle();
            if (notification != null && !notification.isRecycled()) notification.recycle();
        }
    }

    @Test
    public void frameworkArtworkRejectionRetriesTextWithoutStoppingControls() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        AudioService service = createService(instrumentation);
        int[] calls = {0};
        MediaSessionCompat[] sessions = new MediaSessionCompat[1];
        instrumentation.runOnMainSync(() -> sessions[0] = new MediaSessionCompat(
                instrumentation.getTargetContext(), "artwork-fallback-test") {
            @Override
            public void setMetadata(MediaMetadataCompat metadata) {
                if (++calls[0] == 1) {
                    throw new IllegalArgumentException("cannot use a recycled source in createBitmap");
                }
                assertNull(metadata.getBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART));
                super.setMetadata(metadata);
            }
        });
        MediaSessionCompat session = sessions[0];
        setField(service, "mediaSession", session);
        Bitmap bitmap = Bitmap.createBitmap(32, 32, Bitmap.Config.ARGB_8888);
        MediaMetadataCompat metadata = new MediaMetadataCompat.Builder(metadata("fallback", "Still playing"))
                .putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bitmap)
                .build();
        try {
            instrumentation.runOnMainSync(() -> {
                setState(service, 0, false);
                publish(service, metadata, bitmap);
            });
            assertEquals(2, calls[0]);
            assertEquals("Still playing", session.getController().getMetadata()
                    .getString(MediaMetadataCompat.METADATA_KEY_TITLE));
            assertFalse(bitmap.isRecycled());
            assertEquals(PlaybackStateCompat.STATE_PAUSED, session.getController().getPlaybackState().getState());
            assertEquals("fallback", session.getController().getPlaybackState().getExtras()
                    .getString(MediaConstants.PLAYBACK_STATE_EXTRAS_KEY_MEDIA_ID));
        } finally {
            bitmap.recycle();
            instrumentation.runOnMainSync(session::release);
        }
    }

    @Test
    public void playbackErrorsKeepTheirMessageAndUseAStandardFallbackCode() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        AudioService service = createService(instrumentation);
        MediaSessionCompat[] sessions = new MediaSessionCompat[1];
        instrumentation.runOnMainSync(() -> sessions[0] = new MediaSessionCompat(
                instrumentation.getTargetContext(), "playback-error-code-test"));
        MediaSessionCompat session = sessions[0];
        setField(service, "mediaSession", session);
        try {
            for (Integer code : new Integer[] {null, PlaybackStateCompat.ERROR_CODE_NOT_SUPPORTED}) {
                instrumentation.runOnMainSync(() -> service.setState(Collections.emptyList(), 0,
                        new int[0], AudioProcessingState.error, false, 2345, 6000, 1f,
                        SystemClock.elapsedRealtime(), code, "Playback failed", 0, 0, false, 3L));
                PlaybackStateCompat state = session.getController().getPlaybackState();
                assertEquals(PlaybackStateCompat.STATE_ERROR, state.getState());
                assertEquals(code == null ? PlaybackStateCompat.ERROR_CODE_UNKNOWN_ERROR : code,
                        state.getErrorCode());
                assertEquals("Playback failed", state.getErrorMessage().toString());
                assertEquals(2345L, state.getPosition());
                assertEquals(3L, state.getActiveQueueItemId());
            }
        } finally {
            instrumentation.runOnMainSync(session::release);
        }
    }

    private static AudioService createService(Instrumentation instrumentation) {
        AudioService[] services = new AudioService[1];
        instrumentation.runOnMainSync(() -> services[0] = new AudioService());
        return services[0];
    }

    private static void publish(AudioService service, MediaMetadataCompat metadata, Bitmap bitmap) {
        try {
            Method method = AudioService.class.getDeclaredMethod("publishMetadata", MediaMetadataCompat.class, Bitmap.class);
            method.setAccessible(true);
            method.invoke(service, metadata, bitmap);
        } catch (ReflectiveOperationException error) {
            throw new AssertionError("Metadata publication failed", error);
        }
    }

    private static void verifyMetadataPublication(boolean playing) throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        // Supply a real Android session without launching Flutter or replacing
        // the user's queue. Keep its playing or paused mode when metadata arrives.
        AudioService[] services = new AudioService[1];
        MediaSessionCompat[] sessions = new MediaSessionCompat[1];
        instrumentation.runOnMainSync(() -> {
            services[0] = new AudioService();
            sessions[0] = new MediaSessionCompat(
                    instrumentation.getTargetContext(), "metadata-publication-test");
        });
        AudioService service = services[0];
        MediaSessionCompat session = sessions[0];
        setField(service, "mediaSession", session);
        setField(service, "playing", playing);
        MediaControllerCompat controller = session.getController();
        try {
            service.setMetadata(metadata("first", "First song"));
            instrumentation.waitForIdleSync();
            instrumentation.runOnMainSync(() -> setState(service, 0, playing));

            // The Dart state channel can reach Android before the background
            // media worker finishes preparing the next track's artwork.
            instrumentation.runOnMainSync(() -> setState(service, 1, playing));
            service.setMetadata(metadata("second", "Second song"));
            instrumentation.waitForIdleSync();

            assertEquals("Second song", controller.getMetadata().getString(MediaMetadataCompat.METADATA_KEY_TITLE));
            PlaybackStateCompat state = controller.getPlaybackState();
            assertNotNull(state);
            assertEquals(playing ? PlaybackStateCompat.STATE_PLAYING : PlaybackStateCompat.STATE_PAUSED,
                    state.getState());
            assertEquals(1L, state.getActiveQueueItemId());
            assertEquals(6000L, state.getBufferedPosition());
            assertEquals(1.25f, state.getPlaybackSpeed(), 0f);
            if (!playing) assertEquals(2345L, state.getPosition());
            assertEquals(PlaybackStateCompat.ACTION_SKIP_TO_NEXT,
                    state.getActions() & PlaybackStateCompat.ACTION_SKIP_TO_NEXT);
            assertNotNull(state.getExtras());
            assertEquals("second", state.getExtras().getString(MediaConstants.PLAYBACK_STATE_EXTRAS_KEY_MEDIA_ID));
        } finally {
            setField(service, "destroyed", true);
            instrumentation.runOnMainSync(session::release);
        }
    }

    private static void setField(AudioService service, String name, Object value) throws Exception {
        Field field = AudioService.class.getDeclaredField(name);
        field.setAccessible(true);
        field.set(service, value);
    }

    private static MediaMetadataCompat metadata(String id, String title) {
        return new MediaMetadataCompat.Builder()
                .putString(MediaMetadataCompat.METADATA_KEY_MEDIA_ID, id)
                .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
                .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "Test artist")
                .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, 60000)
                .build();
    }

    private static void setState(AudioService service, long index, boolean playing) {
        service.setState(Collections.emptyList(), PlaybackStateCompat.ACTION_SKIP_TO_NEXT,
                new int[0], AudioProcessingState.ready, playing, 2345, 6000, 1.25f,
                SystemClock.elapsedRealtime(), null, null, 0, 0, false, index);
    }
}
