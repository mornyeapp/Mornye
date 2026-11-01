package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Test

class DownloadProgressSequenceTest {
    @Test
    fun advancesOnlyForNewEventsOrAnExplicitReset() {
        assertEquals(5L, downloadProgressSequence("{\"seq\":5}", 4L))
        assertEquals(4L, downloadProgressSequence("{\"seq\":3}", 4L))
        assertEquals(3L, downloadProgressSequence("{\"seq\":3,\"reset\":true}", 4L))
        assertEquals(4L, downloadProgressSequence("{\"seq\":3,\"reset\":\"true\"}", 4L))
        assertEquals(4L, downloadProgressSequence("{\"reset\":true}", 4L))
        assertEquals(4L, downloadProgressSequence("{\"seq\":\"5\"}", 4L))
        assertEquals(5L, downloadProgressSequence("{\"seq\":5.9}", 4L))
    }

    @Test
    fun missingOrInvalidObjectsKeepTheCursorWithoutChangingThePayload() {
        for (payload in listOf("", "null", "[]", "1", "{broken", "{}")) {
            assertEquals(9L, downloadProgressSequence(payload, 9L))
        }
    }
}
