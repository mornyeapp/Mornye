@file:OptIn(UnstableApi::class)

package com.zarz.mornye

import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.ParserException
import androidx.media3.common.PlaybackException
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSourceException
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.FileDescriptorDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import androidx.media3.exoplayer.upstream.LoadErrorHandlingPolicy
import androidx.media3.extractor.DefaultExtractorsFactory
import java.io.IOException

/**
 * A duplicate of an app-owned `/proc/self/fd/<n>` lease. AppFuse proxies
 * allow only the original open, so every read goes through media3's
 * [FileDescriptorDataSource], which seeks the descriptor itself on each open
 * (seeks and load retries) and never reopens a path. The duplicate closes
 * once its item has left the playlist and the last reader has closed, so a
 * loader still unwinding after a removal never reads a closed descriptor.
 */
internal class DescriptorSource private constructor(
    private val descriptor: ParcelFileDescriptor,
) : DataSource.Factory {
    private val lock = Any()
    private var readers = 0
    private var retired = false
    private var closed = false

    override fun createDataSource(): DataSource = Reader()

    /** The item left the playlist; close as soon as no reader is open. */
    fun retire() {
        synchronized(lock) {
            retired = true
            if (readers == 0) closeDescriptor()
        }
    }

    private fun closeDescriptor() {
        if (closed) return
        closed = true
        runCatching { descriptor.close() }
    }

    private inner class Reader : DataSource {
        private val delegate = FileDescriptorDataSource(descriptor.fileDescriptor, 0, C.LENGTH_UNSET.toLong())
        private var counted = false

        override fun addTransferListener(transferListener: TransferListener) {
            delegate.addTransferListener(transferListener)
        }

        override fun open(dataSpec: DataSpec): Long {
            synchronized(lock) {
                if (retired) throw IOException("Descriptor source was released")
                readers++
                counted = true
            }
            return delegate.open(dataSpec)
        }

        override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
            delegate.read(buffer, offset, length)

        override fun getUri(): Uri? = delegate.uri

        override fun getResponseHeaders(): Map<String, List<String>> = delegate.responseHeaders

        override fun close() {
            try {
                delegate.close()
            } finally {
                if (counted) {
                    counted = false
                    synchronized(lock) {
                        readers--
                        if (retired && readers == 0) closeDescriptor()
                    }
                }
            }
        }
    }

    companion object {
        /** Throws when [fd] is not an open descriptor of this process. */
        fun duplicate(fd: Int): DescriptorSource = DescriptorSource(ParcelFileDescriptor.fromFd(fd))
    }
}

/**
 * media3's default retry policy that also reports when a load has failed
 * for good: the error is not retried, or it has been retried as often as the
 * period tolerates before throwing. media3 throws a queued item's load
 * failure only once playback reaches it, and a current item shorter than the
 * output buffer never starts (the track waits for data that cannot come),
 * so the player acts on this report instead. Called on the media3 playback
 * thread.
 */
private class FatalLoadPolicy(private val onFatal: (IOException) -> Unit) : DefaultLoadErrorHandlingPolicy() {
    override fun getRetryDelayMsFor(loadErrorInfo: LoadErrorHandlingPolicy.LoadErrorInfo): Long {
        val delay = super.getRetryDelayMsFor(loadErrorInfo)
        val retries = getMinimumLoadableRetryCount(loadErrorInfo.mediaLoadData.dataType)
        if (delay == C.TIME_UNSET || loadErrorInfo.errorCount > retries) onFatal(loadErrorInfo.exception)
        return delay
    }
}

/** The [PlaybackException] code media3 reports for a failed load. */
internal fun loadErrorCode(error: IOException): Int = when (error) {
    is DataSourceException -> error.reason
    is ParserException ->
        if (error.contentIsMalformed) PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED
        else PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED
    else -> PlaybackException.ERROR_CODE_IO_UNSPECIFIED
}

/** Builds progressive media sources for each `uri` form of the contract. */
internal class Media3SourceFactory(context: Context) {
    private val extractors = DefaultExtractorsFactory().setConstantBitrateSeekingEnabled(true)
    private val defaultData = DefaultDataSource.Factory(
        context.applicationContext,
        DefaultHttpDataSource.Factory().setAllowCrossProtocolRedirects(true),
    )

    class Built(val source: MediaSource, val descriptor: DescriptorSource?)

    /**
     * Throws when a descriptor cannot be duplicated. [onFatal] runs on the
     * media3 playback thread when a load fails for good.
     */
    fun build(kind: Media3SourceKind, mediaId: String, onFatal: (IOException) -> Unit): Built {
        val item = MediaItem.Builder().setMediaId(mediaId)
        val policy = FatalLoadPolicy(onFatal)
        return when (kind) {
            is Media3SourceKind.Descriptor -> {
                val descriptor = DescriptorSource.duplicate(kind.fd)
                // The URI only names the item; reads never resolve it.
                val source = ProgressiveMediaSource.Factory(descriptor, extractors)
                    .setLoadErrorHandlingPolicy(policy)
                    .createMediaSource(item.setUri(Uri.parse("fd://${kind.fd}")).build())
                Built(source, descriptor)
            }
            is Media3SourceKind.File ->
                Built(progressive(item.setUri(Uri.fromFile(java.io.File(kind.path))), policy), null)
            is Media3SourceKind.Local -> Built(progressive(item.setUri(Uri.parse(kind.uri)), policy), null)
            is Media3SourceKind.Network -> Built(progressive(item.setUri(Uri.parse(kind.url)), policy), null)
        }
    }

    private fun progressive(item: MediaItem.Builder, policy: LoadErrorHandlingPolicy): MediaSource =
        ProgressiveMediaSource.Factory(defaultData, extractors)
            .setLoadErrorHandlingPolicy(policy)
            .createMediaSource(item.build())
}
