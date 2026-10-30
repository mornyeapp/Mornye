package com.ryanheise.audioservice;

import org.junit.Test;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;

public class RecentArtCacheTest {
    @Test
    public void keepsOnlyTheLastFewCoversThroughALongSession() {
        RecentArtCache<Object> cache = new RecentArtCache<>(3);
        Object[] covers = new Object[20];
        for (int i = 0; i < covers.length; i++) {
            covers[i] = new Object();
            cache.put("cover-" + i, covers[i]);
            // Each track sends its media item again for its duration and art.
            assertSame(covers[i], cache.get("cover-" + i));
            assertEquals(Math.min(i + 1, 3), cache.size());
        }
        assertNull(cache.get("cover-16"));
        assertSame(covers[17], cache.get("cover-17"));
        assertSame(covers[18], cache.get("cover-18"));
        assertSame(covers[19], cache.get("cover-19"));
    }

    @Test
    public void aReplayedCoverOutlivesOlderOnes() {
        RecentArtCache<String> cache = new RecentArtCache<>(3);
        cache.put("first", "a");
        cache.put("second", "b");
        cache.put("third", "c");
        assertEquals("a", cache.get("first"));
        cache.put("fourth", "d");
        assertNull(cache.get("second"));
        assertEquals("a", cache.get("first"));
        cache.put("third", "c2");
        cache.put("fifth", "e");
        assertNull(cache.get("fourth"));
        assertEquals("c2", cache.get("third"));
        assertEquals(3, cache.size());
    }

    @Test
    public void trimKeepsOnlyTheCurrentCover() {
        RecentArtCache<Object> cache = new RecentArtCache<>(3);
        Object current = new Object();
        cache.put("earlier", new Object());
        cache.put("current", current);
        cache.put("next", new Object());
        cache.evictAllExcept(current);
        assertEquals(1, cache.size());
        assertSame(current, cache.get("current"));
        assertNull(cache.get("earlier"));
        assertNull(cache.get("next"));

        cache.evictAllExcept(null);
        assertEquals(0, cache.size());
        cache.put("current", current);
        cache.evictAll();
        assertNull(cache.get("current"));
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsAnEmptyLimit() {
        new RecentArtCache<String>(0);
    }
}
