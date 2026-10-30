package com.ryanheise.audioservice;

import android.graphics.Bitmap;
import android.os.Bundle;
import android.support.v4.media.MediaMetadataCompat;

/** Keeps framework bitmap ownership separate from the service's artwork cache. */
final class MediaArtwork {
    static final int MAX_DIMENSION = 512;

    private MediaArtwork() {}

    static Bitmap copy(Bitmap source, int maxDimension) {
        if (source == null || source.isRecycled()) return null;
        Bitmap scaled = source;
        try {
            scaled = scale(source, maxDimension);
            return scaled.copy(Bitmap.Config.ARGB_8888, false);
        } catch (IllegalArgumentException | IllegalStateException error) {
            return null;
        } finally {
            if (scaled != source && !scaled.isRecycled()) scaled.recycle();
        }
    }

    /**
     * Scales a freshly decoded cover down to the largest copy the session
     * takes, recycling the decoded one. Session copies are then the same
     * pixels as copies scaled from the decoded bitmap.
     */
    static Bitmap bound(Bitmap decoded) {
        Bitmap scaled;
        try {
            scaled = scale(decoded, MAX_DIMENSION);
        } catch (IllegalArgumentException | IllegalStateException error) {
            return decoded;
        }
        if (scaled != decoded) decoded.recycle();
        return scaled;
    }

    private static Bitmap scale(Bitmap source, int maxDimension) {
        int width = source.getWidth();
        int height = source.getHeight();
        if (width <= maxDimension && height <= maxDimension) return source;
        float scale = (float) maxDimension / Math.max(width, height);
        return Bitmap.createScaledBitmap(source,
                Math.max(1, Math.round(width * scale)),
                Math.max(1, Math.round(height * scale)), true);
    }

    static MediaMetadataCompat sanitize(MediaMetadataCompat metadata) {
        return transform(metadata, false, false);
    }

    static MediaMetadataCompat forSession(MediaMetadataCompat metadata) {
        return transform(metadata, true, false);
    }

    static MediaMetadataCompat withoutArtwork(MediaMetadataCompat metadata) {
        return transform(metadata, false, true);
    }

    private static MediaMetadataCompat transform(MediaMetadataCompat metadata,
            boolean copyArtwork, boolean omit) {
        MediaMetadataCompat.Builder builder = new MediaMetadataCompat.Builder(metadata);
        Bundle values = metadata.getBundle();
        for (String key : values.keySet()) {
            Object value = values.get(key);
            if (!(value instanceof Bitmap)) continue;
            Bitmap bitmap = (Bitmap) value;
            // Each key gets its own copy: some frameworks consume a bitmap
            // while scaling it, before visiting another key with the same art.
            builder.putBitmap(key, omit || bitmap.isRecycled() ? null
                    : copyArtwork ? copy(bitmap, MAX_DIMENSION) : bitmap);
        }
        return builder.build();
    }
}
