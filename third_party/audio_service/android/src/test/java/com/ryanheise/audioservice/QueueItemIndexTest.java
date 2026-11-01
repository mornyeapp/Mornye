package com.ryanheise.audioservice;

import java.util.HashMap;
import java.util.Map;
import org.junit.Test;
import static org.junit.Assert.assertEquals;

public class QueueItemIndexTest {
    @Test
    public void legacyQueuesKeepTheirOriginalPositionIds() {
        assertEquals(7L, QueueItemIndex.fromExtras(null, 7));
        assertEquals(7L, QueueItemIndex.fromExtras(new HashMap<>(), 7));
    }

    @Test
    public void windowsKeepAbsoluteIdsEvenWhenAnotherWindowIsPending() {
        Map<String, Object> oldWindow = new HashMap<>();
        oldWindow.put(QueueItemIndex.EXTRA, 9000);
        Map<String, Object> newWindow = new HashMap<>();
        newWindow.put(QueueItemIndex.EXTRA, 14900L);
        assertEquals(9000L, QueueItemIndex.fromExtras(oldWindow, 0));
        assertEquals(14900L, QueueItemIndex.fromExtras(newWindow, 0));
        assertEquals(9000L, QueueItemIndex.fromExtras(oldWindow, 0));
    }

    @Test
    public void invalidReservedValuesCannotBecomeNativeQueueIds() {
        Map<String, Object> extras = new HashMap<>();
        for (Object value : new Object[] {null, "9000", -1, -7L, 9.5, true}) {
            extras.put(QueueItemIndex.EXTRA, value);
            assertEquals(8L, QueueItemIndex.fromExtras(extras, 8));
        }
    }

    @Test
    public void positionBasedEditsUseThePublishedWindowIncludingAppend() {
        assertEquals(9000, QueueItemIndex.fromPosition(9000, 500, 0));
        assertEquals(9499, QueueItemIndex.fromPosition(9000, 500, 499));
        assertEquals(9500, QueueItemIndex.fromPosition(9000, 500, 500));
        assertEquals(-1, QueueItemIndex.fromPosition(9000, 500, -1));
        assertEquals(501, QueueItemIndex.fromPosition(9000, 500, 501));
        assertEquals(12, QueueItemIndex.fromPosition(0, 500, 12));
    }
}
