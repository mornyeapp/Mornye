package com.ryanheise.audioservice;

import java.util.Map;

final class QueueItemIndex {
    static final String EXTRA = "com.ryanheise.audio_service.queueIndex";

    private QueueItemIndex() { }

    static long fromExtras(Map<?, ?> extras, int fallback) {
        Object value = extras == null ? null : extras.get(EXTRA);
        if (value instanceof Integer || value instanceof Long) {
            long index = ((Number)value).longValue();
            if (index >= 0) return index;
        }
        return fallback;
    }

    static int fromPosition(long firstId, int size, int index) {
        if (index < 0 || index > size) return index;
        return (int)firstId + index;
    }
}
