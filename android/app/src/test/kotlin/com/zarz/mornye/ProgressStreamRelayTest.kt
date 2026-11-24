package com.zarz.mornye

import io.flutter.plugin.common.EventChannel
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

class ProgressStreamRelayTest {
    private class Host {
        var sink: EventChannel.EventSink? = null
        var stops = 0
    }

    private class Sink : EventChannel.EventSink {
        override fun success(event: Any?) = Unit
        override fun error(code: String, message: String?, details: Any?) = Unit
        override fun endOfStream() = Unit
    }

    private fun relay() = ProgressStreamRelay<Host>(
        start = { host, sink -> host.sink = sink },
        stop = { host ->
            host.sink = null
            host.stops++
        },
    )

    @Test
    fun aListenerIsHandedToTheNextHost() {
        val relay = relay()
        val first = Host()
        val second = Host()
        val sink = Sink()

        relay.attach(first)
        relay.onListen(null, sink)
        assertSame(sink, first.sink)

        relay.detach(first)
        assertNull(first.sink)

        relay.attach(second)
        assertSame(sink, second.sink)

        relay.onCancel(null)
        assertNull(second.sink)
    }

    @Test
    fun aListenWithoutAHostStartsWhenOneAttaches() {
        val relay = relay()
        val host = Host()
        val sink = Sink()

        relay.onListen(null, sink)
        relay.attach(host)

        assertSame(sink, host.sink)
    }

    @Test
    fun aCancelledStreamIsNotStartedOnTheNextHost() {
        val relay = relay()
        val first = Host()
        val second = Host()

        relay.attach(first)
        relay.onListen(null, Sink())
        relay.onCancel(null)
        relay.detach(first)
        relay.attach(second)

        assertNull(second.sink)
    }

    @Test
    fun aHostThatLeavesLateDoesNotStopItsSuccessor() {
        val relay = relay()
        val first = Host()
        val second = Host()
        val sink = Sink()

        relay.attach(first)
        relay.onListen(null, sink)
        relay.attach(second)
        assertNull(first.sink)
        relay.detach(first)

        assertSame(sink, second.sink)
        assertEquals(0, second.stops)
    }
}
