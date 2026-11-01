package com.zarz.mornye

import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SafReadWorkersTest {
    @Test(timeout = 5000L)
    fun cancellingAnInFlightReadStopsTheScanWithoutWaitingForTheProvider() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val interrupted = CountDownLatch(1)
        val cancelled = AtomicBoolean(false)
        val completed = AtomicReference<Boolean>()
        val failure = AtomicReference<Throwable>()
        val consumed = mutableListOf<Int>()
        val scanner = thread(name = "saf-cancellation-test") {
            try {
                completed.set(runSafReadsInOrder(listOf(1), cancelled::get, task = { item ->
                    entered.countDown()
                    try {
                        release.await()
                    } catch (error: InterruptedException) {
                        interrupted.countDown()
                        throw error
                    }
                    item
                }) { _, result -> consumed.add(result.getOrThrow()) })
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            cancelled.set(true)
            scanner.join(1500L)
            assertFalse("Cancellation waited for the provider read", scanner.isAlive)
            assertEquals(null, failure.get())
            assertEquals(false, completed.get())
            assertTrue(consumed.isEmpty())
            assertTrue(interrupted.await(1, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            scanner.join(1500L)
        }
    }

    @Test(timeout = 5000L)
    fun aPauseCheckpointHoldsCompletedRowsUntilTheScanResumes() {
        val taskEntered = CountDownLatch(1)
        val releaseTask = CountDownLatch(1)
        val checkpointEntered = CountDownLatch(1)
        val resume = CountDownLatch(1)
        val paused = AtomicBoolean(false)
        val consumed = CountDownLatch(1)
        val failure = AtomicReference<Throwable>()
        val scanner = thread(name = "saf-pause-test") {
            try {
                assertTrue(runSafReadsInOrder(listOf(1), cancelled = {
                    if (paused.get()) {
                        checkpointEntered.countDown()
                        resume.await()
                    }
                    false
                }, task = { item ->
                    taskEntered.countDown()
                    releaseTask.await()
                    item
                }) { _, result ->
                    assertEquals(1, result.getOrThrow())
                    consumed.countDown()
                })
            } catch (error: Throwable) {
                failure.set(error)
            }
        }
        try {
            assertTrue(taskEntered.await(1, TimeUnit.SECONDS))
            paused.set(true)
            releaseTask.countDown()
            assertTrue(checkpointEntered.await(1, TimeUnit.SECONDS))
            assertEquals(1L, consumed.count)
            paused.set(false)
            resume.countDown()
            scanner.join(1500L)
            assertFalse(scanner.isAlive)
            assertEquals(null, failure.get())
            assertEquals(0L, consumed.count)
        } finally {
            releaseTask.countDown()
            resume.countDown()
            scanner.join(1500L)
        }
    }

    @Test
    fun resultsAndFailuresRemainInInputOrder() {
        val consumed = mutableListOf<Pair<Int, Result<Int>>>()
        assertTrue(runSafReadsInOrder((1..30).toList(), { false }, task = { item ->
            if (item == 2) throw IOException("Unreadable document")
            item * 2
        }) { item, result -> consumed.add(item to result) })

        assertEquals((1..30).toList(), consumed.map { it.first })
        assertEquals(2, consumed[0].second.getOrThrow())
        assertTrue(consumed[1].second.exceptionOrNull() is IOException)
        assertEquals(60, consumed.last().second.getOrThrow())
    }
}
