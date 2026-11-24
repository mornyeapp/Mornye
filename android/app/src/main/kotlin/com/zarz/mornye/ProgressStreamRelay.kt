package com.zarz.mornye

import io.flutter.plugin.common.EventChannel

/**
 * One progress stream of the shared engine. The Dart listener outlives an
 * Activity, so the sink is kept here and handed to each Activity in turn.
 */
internal class ProgressStreamRelay<H : Any>(
    private val start: (H, EventChannel.EventSink) -> Unit,
    private val stop: (H) -> Unit,
) : EventChannel.StreamHandler {
    private var sink: EventChannel.EventSink? = null
    private var host: H? = null

    fun attach(next: H) {
        host?.takeIf { it !== next }?.let(stop)
        host = next
        sink?.let { start(next, it) }
    }

    fun detach(previous: H) {
        stop(previous)
        if (host === previous) host = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        val current = host ?: return
        if (events == null) stop(current) else start(current, events)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        host?.let(stop)
    }
}
