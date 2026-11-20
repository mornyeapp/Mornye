package com.ryanheise.audioservice;

/**
 * Converts the conventional single-button headset gesture into a transport
 * command. Timing is owned by {@link AudioService.MediaSessionCallback}; this
 * class only keeps the current gesture easy to test.
 */
final class HeadsetClickTracker {
    private int clickCount;

    void addClick() {
        // More than three presses still means "previous". Bounding the count
        // also prevents an accidental stuck button from overflowing it.
        clickCount = Math.min(clickCount + 1, 3);
    }

    MediaButton consumeButton() {
        final int clicks = clickCount;
        clickCount = 0;
        if (clicks == 2) return MediaButton.next;
        if (clicks >= 3) return MediaButton.previous;
        return MediaButton.media;
    }

    void clear() {
        clickCount = 0;
    }
}
