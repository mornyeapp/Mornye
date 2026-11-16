package com.ryanheise.audioservice;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import org.junit.Test;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotSame;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertSame;

public class ArtCopiesTest {
    /** A cover or a copy of one; recycled ones are unusable. */
    private static final class Art {
        final String name;
        boolean recycled;

        Art(String name) {
            this.name = name;
        }
    }

    private final List<String> copied = new ArrayList<>();
    private final ArtCopies<Art> copies = new ArtCopies<>(art -> !art.recycled);

    private Art copy(Art source, String key) {
        return copies.get(source, key, art -> {
            copied.add(art.name + "@" + key);
            return new Art(art.name + "@" + key);
        });
    }

    @Test
    public void lyricLinesOverTheSameCoverCopyItOncePerKey() {
        Art cover = new Art("cover");
        Set<Art> shown = new HashSet<>();
        for (int line = 0; line < 100; line++) {
            shown.add(copy(cover, "album"));
            shown.add(copy(cover, "icon"));
            shown.add(copy(cover, "notification"));
        }
        assertEquals(3, shown.size());
        assertEquals(3, copied.size());
        assertNotSame(copy(cover, "album"), copy(cover, "icon"));
    }

    @Test
    public void anotherCoverGetsNewCopiesAndDropsTheOldOnes() {
        Art first = new Art("first");
        Art album = copy(first, "album");
        Art second = new Art("second");
        Art next = copy(second, "album");
        assertNotSame(album, next);
        assertEquals(1, copies.size());
        assertNotSame(album, copy(first, "album"));
        assertEquals(3, copied.size());
        assertEquals(false, album.recycled);
    }

    @Test
    public void aRecycledCopyIsMadeAgainAndARecycledCoverHasNone() {
        Art cover = new Art("cover");
        Art album = copy(cover, "album");
        album.recycled = true;
        Art again = copy(cover, "album");
        assertNotSame(album, again);
        assertSame(again, copy(cover, "album"));
        assertEquals(2, copied.size());

        cover.recycled = true;
        assertNull(copy(cover, "album"));
        assertNull(copies.get(null, "album", art -> art));
        assertEquals(2, copied.size());
    }

    @Test
    public void aFailedCopyIsTriedAgainAndClearForgetsEverything() {
        Art cover = new Art("cover");
        assertNull(copies.get(cover, "album", art -> null));
        assertEquals(0, copies.size());
        Art album = copy(cover, "album");
        assertSame(album, copy(cover, "album"));
        copies.clear();
        assertEquals(0, copies.size());
        assertNotSame(album, copy(cover, "album"));
    }
}
