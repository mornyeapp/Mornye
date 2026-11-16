package com.ryanheise.audioservice;

import java.util.HashMap;
import java.util.Map;

/**
 * The copies the session and notification take of the current cover, kept
 * while the cover is the same object, so an update that changes only text
 * (a lock screen lyric line) reuses them instead of copying the art again.
 * Nothing is recycled: the session and notification may still show a copy.
 */
final class ArtCopies<T> {
    interface Copier<T> {
        T copy(T source);
    }

    interface Check<T> {
        boolean usable(T value);
    }

    private final Check<T> usable;
    private final Map<String, T> copies = new HashMap<>();
    private T source;

    ArtCopies(Check<T> usable) {
        this.usable = usable;
    }

    /** The copy of source for key: a kept one while it is intact, else a new one. */
    synchronized T get(T source, String key, Copier<T> copier) {
        if (source == null || !usable.usable(source)) return null;
        if (source != this.source) {
            copies.clear();
            this.source = source;
        }
        T copy = copies.get(key);
        if (copy != null && usable.usable(copy)) return copy;
        copy = copier.copy(source);
        if (copy == null) {
            copies.remove(key);
        } else {
            copies.put(key, copy);
        }
        return copy;
    }

    synchronized void clear() {
        copies.clear();
        source = null;
    }

    synchronized int size() {
        return copies.size();
    }
}
