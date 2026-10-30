package com.ryanheise.audioservice;

import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.Map;

/** Keeps the decoded art of the last few media items, so a skip back or replay reuses it. */
final class RecentArtCache<T> {
    private final int limit;
    private final Map<String, T> entries = new LinkedHashMap<>(8, 0.75f, true);

    RecentArtCache(int limit) {
        if (limit < 1) throw new IllegalArgumentException("limit must be positive");
        this.limit = limit;
    }

    synchronized T get(String key) {
        return entries.get(key);
    }

    synchronized void put(String key, T value) {
        entries.put(key, value);
        Iterator<T> eldest = entries.values().iterator();
        while (entries.size() > limit) {
            eldest.next();
            eldest.remove();
        }
    }

    synchronized void remove(String key) {
        entries.remove(key);
    }

    /** Drops every entry but the one holding kept. Nothing is recycled: the session may still show it. */
    synchronized void evictAllExcept(T kept) {
        Iterator<T> values = entries.values().iterator();
        while (values.hasNext()) {
            if (values.next() != kept) values.remove();
        }
    }

    synchronized void evictAll() {
        entries.clear();
    }

    synchronized int size() {
        return entries.size();
    }
}
