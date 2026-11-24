package com.ryanheise.audioservice;

import org.junit.Test;

import static org.junit.Assert.assertEquals;

public class HeadsetClickTrackerTest {
    @Test
    public void singlePressTogglesPlayback() {
        HeadsetClickTracker tracker = new HeadsetClickTracker();

        tracker.addClick();

        assertEquals(MediaButton.media, tracker.consumeButton());
    }

    @Test
    public void doublePressSkipsToTheNextTrack() {
        HeadsetClickTracker tracker = new HeadsetClickTracker();

        tracker.addClick();
        tracker.addClick();

        assertEquals(MediaButton.next, tracker.consumeButton());
    }

    @Test
    public void threeOrMorePressesSkipToThePreviousTrack() {
        HeadsetClickTracker tracker = new HeadsetClickTracker();

        tracker.addClick();
        tracker.addClick();
        tracker.addClick();
        tracker.addClick();

        assertEquals(MediaButton.previous, tracker.consumeButton());
    }

    @Test
    public void consumingOrClearingDoesNotAffectTheNextGesture() {
        HeadsetClickTracker tracker = new HeadsetClickTracker();

        tracker.addClick();
        assertEquals(MediaButton.media, tracker.consumeButton());
        tracker.addClick();
        tracker.clear();
        tracker.addClick();
        tracker.addClick();

        assertEquals(MediaButton.next, tracker.consumeButton());
    }
}
