package com.ryanheise.audioservice;

import android.os.Handler;
import android.os.PowerManager;

/** A renewable playback lease, released when playback pauses or stops. */
final class PlaybackWakeLock {
    private final PowerManager.WakeLock lock;
    private final Handler handler;
    private final long timeoutMs;
    private final long renewalMs;
    private boolean active;
    private final Runnable renewal = this::acquireIfActive;

    PlaybackWakeLock(PowerManager.WakeLock lock, Handler handler) {
        this(lock, handler, 10 * 60 * 1000L, 5 * 60 * 1000L);
    }

    PlaybackWakeLock(PowerManager.WakeLock lock, Handler handler,
            long timeoutMs, long renewalMs) {
        if (renewalMs <= 0 || timeoutMs <= renewalMs) {
            throw new IllegalArgumentException("Renewal must precede the wake lock timeout");
        }
        this.lock = lock;
        this.handler = handler;
        this.timeoutMs = timeoutMs;
        this.renewalMs = renewalMs;
        lock.setReferenceCounted(false);
    }

    void acquire() {
        active = true;
        acquireIfActive();
    }

    private void acquireIfActive() {
        if (!active) return;
        lock.acquire(timeoutMs);
        handler.removeCallbacks(renewal);
        handler.postDelayed(renewal, renewalMs);
    }

    void release() {
        active = false;
        handler.removeCallbacks(renewal);
        if (lock.isHeld()) lock.release();
    }
}
