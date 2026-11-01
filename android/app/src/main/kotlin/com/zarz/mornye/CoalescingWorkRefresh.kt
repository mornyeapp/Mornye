package com.zarz.mornye

/** Keeps one pending refresh while the publisher runs outside the state lock. */
internal class CoalescingWorkRefresh(
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val refresh: () -> Unit,
    private val intervalMs: Long = 500L,
) {
    private val lock = Any()
    private var scheduled = false
    private var running = false
    private var pending = false
    private var immediate = false
    private var closed = false
    private val task = Runnable { flush() }

    fun request(immediately: Boolean = false) {
        synchronized(lock) {
            if (closed) return
            pending = true
            if (immediately && !immediate) {
                immediate = true
                if (scheduled) {
                    cancel(task)
                    scheduled = false
                }
            }
            if (!running && !scheduled) enqueue()
        }
    }

    fun close() {
        synchronized(lock) {
            closed = true
            pending = false
            if (scheduled) cancel(task)
            scheduled = false
        }
    }

    private fun enqueue() {
        scheduled = true
        schedule(task, if (immediate) 0L else intervalMs)
    }

    private fun flush() {
        synchronized(lock) {
            scheduled = false
            if (closed || !pending) return
            pending = false
            immediate = false
            running = true
        }
        try {
            refresh()
        } finally {
            synchronized(lock) {
                running = false
                if (!closed && pending && !scheduled) enqueue()
            }
        }
    }
}
