package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class CoalescingWorkRefreshTest {
    private class Scheduler {
        val tasks = mutableListOf<Pair<Runnable, Long>>()

        fun post(task: Runnable, delay: Long) {
            tasks.add(task to delay)
        }

        fun cancel(task: Runnable) {
            tasks.removeAll { it.first === task }
        }

        fun next(): Runnable = tasks.removeAt(0).first
    }

    @Test
    fun aBurstPublishesOnlyTheLatestWorkWithOneQueuedTask() {
        val scheduler = Scheduler()
        val published = mutableListOf<Int>()
        var progress = 0
        val refresh = CoalescingWorkRefresh(scheduler::post, scheduler::cancel, { published.add(progress) })
        for (value in 1..1000) {
            progress = value
            refresh.request()
        }
        assertEquals(1, scheduler.tasks.size)
        assertEquals(500L, scheduler.tasks.single().second)
        scheduler.next().run()
        assertEquals(listOf(1000), published)
        assertTrue(scheduler.tasks.isEmpty())
    }

    @Test
    fun stopBypassesTheProgressDelayAndReadsTheRemainingWork() {
        val scheduler = Scheduler()
        val works = linkedMapOf("scan" to 1, "update" to 2)
        val published = mutableListOf<Int?>()
        val refresh = CoalescingWorkRefresh(scheduler::post, scheduler::cancel, { published.add(works.values.lastOrNull()) })
        refresh.request()
        works.remove("update")
        refresh.request(immediately = true)
        assertEquals(1, scheduler.tasks.size)
        assertEquals(0L, scheduler.tasks.single().second)
        scheduler.next().run()
        assertEquals(listOf(1), published)
        works.clear()
        refresh.request(immediately = true)
        scheduler.next().run()
        assertEquals(listOf(1, null), published)
    }

    @Test(timeout = 3000L)
    fun aBlockedPublisherDoesNotBlockUpdatesOrQueueAnotherThousandWrites() {
        val scheduler = Scheduler()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val refresh = CoalescingWorkRefresh(scheduler::post, scheduler::cancel, {
            entered.countDown()
            assertTrue(release.await(2, TimeUnit.SECONDS))
        })
        refresh.request()
        val worker = Thread(scheduler.next()).apply { start() }
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            repeat(1000) { refresh.request() }
            refresh.request(immediately = true)
            assertTrue(scheduler.tasks.isEmpty())
        } finally {
            release.countDown()
            worker.join(1000L)
        }
        assertEquals(1, scheduler.tasks.size)
        assertEquals(0L, scheduler.tasks.single().second)
        refresh.close()
        assertTrue(scheduler.tasks.isEmpty())
    }

    @Test
    fun destroyingTheOwnerDropsPendingProgressAndRejectsLateUpdates() {
        val scheduler = Scheduler()
        var writes = 0
        val refresh = CoalescingWorkRefresh(scheduler::post, scheduler::cancel, { writes++ })
        refresh.request()
        val oldTask = scheduler.tasks.single().first
        refresh.close()
        oldTask.run()
        refresh.request(immediately = true)
        assertTrue(scheduler.tasks.isEmpty())
        assertEquals(0, writes)
    }

    @Test(timeout = 3000L)
    fun destroyingDuringAPublishNeverReschedulesPendingProgress() {
        val scheduler = Scheduler()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val refresh = CoalescingWorkRefresh(scheduler::post, scheduler::cancel, {
            entered.countDown()
            assertTrue(release.await(2, TimeUnit.SECONDS))
        })
        refresh.request()
        val worker = Thread(scheduler.next()).apply { start() }
        try {
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            refresh.request()
            refresh.close()
        } finally {
            release.countDown()
            worker.join(1000L)
        }
        assertTrue(scheduler.tasks.isEmpty())
    }
}
