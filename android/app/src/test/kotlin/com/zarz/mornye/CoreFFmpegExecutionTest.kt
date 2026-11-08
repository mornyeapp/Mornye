package com.zarz.mornye

import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private const val TIMEOUT_SECONDS = 2L

private fun createTempDirectory(): File {
    val directory = File.createTempFile("core-ffmpeg-command-", "")
    check(directory.delete()) { "failed to remove temporary file" }
    check(directory.mkdir()) { "failed to create temporary directory" }
    return directory
}

private fun awaitWorkerLatch(
    latch: CountDownLatch,
    name: String,
    failures: AtomicReference<Throwable?>,
): Boolean {
    val reached = latch.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)
    if (!reached) {
        failures.compareAndSet(null, AssertionError("worker timed out waiting for $name"))
    }
    return reached
}

private data class Completion(
    val success: Boolean,
    val output: String,
    val error: String,
)

private class FakeCoreExtensionExecution : CoreExtensionExecution {
    private class PendingBatch(val commands: List<CoreFFmpegCommand>)

    private val batches = LinkedBlockingQueue<PendingBatch>()
    private val closedBatch = PendingBatch(emptyList())
    private val active = ConcurrentHashMap.newKeySet<String>()
    private val completions = ConcurrentHashMap<String, Completion>()
    private val completionLatches = ConcurrentHashMap<String, CountDownLatch>()
    private val closed = AtomicBoolean(false)

    val waitEntered = CountDownLatch(1)
    val closedHandle = CountDownLatch(1)
    val secondClose = CountDownLatch(1)
    val closeCalls = AtomicInteger(0)

    fun enqueue(vararg commands: CoreFFmpegCommand) {
        commands.forEach { command ->
            active.add(command.id)
            completionLatches[command.id] = CountDownLatch(1)
        }
        batches.offer(PendingBatch(commands.toList()))
    }

    fun remove(commandId: String) {
        active.remove(commandId)
    }

    fun isActive(commandId: String): Boolean = active.contains(commandId)

    fun isClosed(): Boolean = closed.get()

    fun awaitCompletion(commandId: String): Boolean =
        completionLatches.getValue(commandId).await(TIMEOUT_SECONDS, TimeUnit.SECONDS)

    fun hasCompletion(commandId: String): Boolean = completions.containsKey(commandId)

    fun completion(commandId: String): Completion = completions.getValue(commandId)

    override fun download(requestJson: String): String = error("unused fake download")

    override fun resolveStream(requestJson: String): String =
        error("unused fake resolve-stream")

    override fun postProcess(inputJson: String, metadataJson: String): String =
        error("unused fake post-process")

    override fun waitPending(timeoutMs: Long): List<CoreFFmpegCommand> {
        waitEntered.countDown()
        if (closed.get()) throw IllegalStateException("execution closed")
        val batch = batches.poll(timeoutMs, TimeUnit.MILLISECONDS) ?: return emptyList()
        if (batch === closedBatch) throw IllegalStateException("execution closed")
        return batch.commands
    }

    override fun commandIsActive(commandId: String): Boolean = active.contains(commandId)

    override fun complete(
        commandId: String,
        success: Boolean,
        output: String,
        error: String,
    ) {
        completions[commandId] = Completion(success, output, error)
        active.remove(commandId)
        completionLatches.getValue(commandId).countDown()
    }

    override fun close() {
        val calls = closeCalls.incrementAndGet()
        if (calls >= 2) secondClose.countDown()
        if (closed.compareAndSet(false, true)) {
            closedHandle.countDown()
            batches.offer(closedBatch)
        }
    }
}

class CoreFFmpegExecutionTest {
    @Test
    fun backendCancellationRemainsCancellationForNativeFinalization() {
        val execution = FakeCoreExtensionExecution()
        val failure = runCatching {
            withCoreFFmpegExecution(execution) { throw IllegalStateException("download cancelled") }
        }.exceptionOrNull()
        assertTrue(failure is java.util.concurrent.CancellationException)
        assertTrue(failure?.cause is IllegalStateException)
        assertTrue(execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
    }

    @Test
    fun callerFinishingDoesNotInterruptClaimedCommandOrCloseHandle() {
        val execution = FakeCoreExtensionExecution()
        val commandStarted = CountDownLatch(1)
        val releaseCommand = CountDownLatch(1)
        val workerFailure = AtomicReference<Throwable?>(null)
        execution.enqueue(CoreFFmpegCommand("command-b", arrayOf("convert-b")))

        try {
            val result = withCoreFFmpegExecution(
                execution,
                execute = { arguments, cancelled ->
                    if (arguments.firstOrNull() != "convert-b") {
                        workerFailure.compareAndSet(
                            null,
                            AssertionError("unexpected command: ${arguments.toList()}"),
                        )
                        false to "unexpected command"
                    } else if (cancelled()) {
                        workerFailure.compareAndSet(
                            null,
                            AssertionError("claimed command B was cancelled"),
                        )
                        false to "cancelled"
                    } else {
                        commandStarted.countDown()
                        if (!awaitWorkerLatch(releaseCommand, "command B release", workerFailure)) {
                            false to "worker timed out"
                        } else {
                            true to "command B complete"
                        }
                    }
                },
            ) {
                assertTrue(commandStarted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
                "caller A complete"
            }

            assertEquals("caller A complete", result)
            assertFalse(execution.isClosed())
            assertFalse(execution.hasCompletion("command-b"))

            releaseCommand.countDown()
            assertTrue(execution.awaitCompletion("command-b"))
            assertTrue(execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
            assertEquals(true, execution.completion("command-b").success)
            assertNull(workerFailure.get())
        } finally {
            releaseCommand.countDown()
            execution.close()
            execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        }
    }

    @Test
    fun registryRemovalCancelsOnlyCommandAWhileCommandBRemainsActive() {
        val execution = FakeCoreExtensionExecution()
        val commandAStarted = CountDownLatch(1)
        val releaseCommandA = CountDownLatch(1)
        val commandBStarted = CountDownLatch(1)
        val releaseCommandB = CountDownLatch(1)
        val workerFailure = AtomicReference<Throwable?>(null)
        execution.enqueue(
            CoreFFmpegCommand("command-a", arrayOf("convert-a")),
            CoreFFmpegCommand("command-b", arrayOf("convert-b")),
        )

        try {
            val result = withCoreFFmpegExecution(
                execution,
                execute = { arguments, cancelled ->
                    if (arguments.firstOrNull() == "convert-a") {
                        commandAStarted.countDown()
                        if (!awaitWorkerLatch(releaseCommandA, "command A release", workerFailure)) {
                            false to "worker timed out"
                        } else if (!cancelled()) {
                            workerFailure.compareAndSet(
                                null,
                                AssertionError("command A was not cancelled"),
                            )
                            false to "not cancelled"
                        } else {
                            false to "cancelled"
                        }
                    } else if (arguments.firstOrNull() != "convert-b") {
                        workerFailure.compareAndSet(
                            null,
                            AssertionError("unexpected command: ${arguments.toList()}"),
                        )
                        false to "unexpected command"
                    } else if (cancelled()) {
                        workerFailure.compareAndSet(
                            null,
                            AssertionError("command B was cancelled"),
                        )
                        false to "cancelled"
                    } else {
                        commandBStarted.countDown()
                        if (!awaitWorkerLatch(releaseCommandB, "command B release", workerFailure)) {
                            false to "worker timed out"
                        } else {
                            true to "command B complete"
                        }
                    }
                },
            ) {
                assertTrue(commandAStarted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
                execution.remove("command-a")
                releaseCommandA.countDown()
                assertTrue(commandBStarted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
                "caller A complete"
            }

            assertEquals("caller A complete", result)
            assertFalse(execution.isClosed())
            assertTrue(execution.isActive("command-b"))
            assertTrue(execution.awaitCompletion("command-a"))
            assertFalse(execution.completion("command-a").success)
            assertEquals("cancelled", execution.completion("command-a").error)

            releaseCommandB.countDown()
            assertTrue(execution.awaitCompletion("command-b"))
            assertTrue(execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
            assertTrue(execution.completion("command-b").success)
            assertNull(workerFailure.get())
        } finally {
            releaseCommandA.countDown()
            releaseCommandB.countDown()
            execution.close()
            execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        }
    }

    @Test
    fun emptyArgumentsFailAndFollowingCommandStillRuns() {
        val execution = FakeCoreExtensionExecution()
        val validCommandStarted = CountDownLatch(1)
        val releaseValidCommand = CountDownLatch(1)
        val workerFailure = AtomicReference<Throwable?>(null)
        val executed = ConcurrentLinkedQueue<String>()
        execution.enqueue(
            CoreFFmpegCommand("empty-command", emptyArray()),
            CoreFFmpegCommand("valid-command", arrayOf("convert")),
        )

        try {
            val result = withCoreFFmpegExecution(
                execution,
                execute = { arguments, _ ->
                    executed.add(arguments.firstOrNull() ?: "")
                    if (arguments.firstOrNull() != "convert") {
                        workerFailure.compareAndSet(
                            null,
                            AssertionError("empty command reached executor"),
                        )
                        false to "unexpected command"
                    } else {
                        validCommandStarted.countDown()
                        if (!awaitWorkerLatch(
                                releaseValidCommand,
                                "valid command release",
                                workerFailure,
                            )
                        ) {
                            false to "worker timed out"
                        } else {
                            true to "valid command complete"
                        }
                    }
                },
            ) {
                assertTrue(validCommandStarted.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
                "caller complete"
            }

            assertEquals("caller complete", result)
            assertEquals(listOf("convert"), executed.toList())
            assertTrue(execution.awaitCompletion("empty-command"))
            assertFalse(execution.completion("empty-command").success)
            assertEquals("FFmpeg arguments are empty", execution.completion("empty-command").error)

            releaseValidCommand.countDown()
            assertTrue(execution.awaitCompletion("valid-command"))
            assertTrue(execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
            assertTrue(execution.completion("valid-command").success)
            assertNull(workerFailure.get())
        } finally {
            releaseValidCommand.countDown()
            execution.close()
            execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS)
        }
    }

    @Test
    fun closedWaitExitsAndPumpReleasesHandle() {
        val execution = FakeCoreExtensionExecution()
        val workerFailure = AtomicReference<Throwable?>(null)

        val result = withCoreFFmpegExecution(
            execution,
            execute = { _, _ ->
                workerFailure.compareAndSet(null, AssertionError("unexpected command"))
                false to "unexpected command"
            },
        ) {
            assertTrue(execution.waitEntered.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
            execution.close()
            "caller complete"
        }

        assertEquals("caller complete", result)
        assertTrue(execution.closedHandle.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertTrue(execution.secondClose.await(TIMEOUT_SECONDS, TimeUnit.SECONDS))
        assertNull(workerFailure.get())
    }

    @Test
    fun cancelledExecutionPreservesExistingTargetAndCleansStaging() {
        val directory = createTempDirectory()
        try {
            val target = File(directory, "output.flac")
            target.writeText("old output")
            val arguments = arrayOf("-i", "input.wav", target.absolutePath)
            val command = CoreFFmpegCommand("cancel", arguments, target.absolutePath)
            val cancelled = AtomicBoolean(false)
            var receivedArguments: Array<String>? = null
            var staging: File? = null

            val result = executeCoreFFmpegCommand(
                command,
                cancelled = { cancelled.get() },
            ) { received, _ ->
                receivedArguments = received.copyOf()
                staging = File(received.last()).also { it.writeText("partial output") }
                cancelled.set(true)
                true to "converted"
            }

            assertFalse(result.first)
            assertEquals(arguments.dropLast(1).toList(), receivedArguments!!.dropLast(1).toList())
            assertEquals("old output", target.readText())
            assertFalse(staging!!.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun failedExecutionLeavesMissingTargetAndCleansStaging() {
        val directory = createTempDirectory()
        try {
            val target = File(directory, "output.flac")
            val arguments = arrayOf("-i", "input.wav", target.absolutePath)
            val command = CoreFFmpegCommand("failed", arguments, target.absolutePath)
            var staging: File? = null

            val result = executeCoreFFmpegCommand(command, cancelled = { false }) { received, _ ->
                staging = File(received.last()).also { it.writeText("partial output") }
                false to "conversion failed"
            }

            assertFalse(result.first)
            assertFalse(target.exists())
            assertFalse(staging!!.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun successfulExecutionReplacesTargetPreservesInputArgumentsAndCleansStaging() {
        val directory = createTempDirectory()
        try {
            val input = File(directory, "input.wav")
            input.writeText("input")
            val target = File(directory, "output.flac")
            target.writeText("old output")
            val arguments = arrayOf("-i", input.absolutePath, "-c:a", "flac", target.absolutePath)
            val command = CoreFFmpegCommand("success", arguments, target.absolutePath)
            var receivedArguments: Array<String>? = null
            var staging: File? = null

            val result = executeCoreFFmpegCommand(command, cancelled = { false }) { received, _ ->
                receivedArguments = received.copyOf()
                staging = File(received.last()).also { it.writeText("new complete output") }
                true to "converted"
            }

            assertTrue(result.first)
            assertEquals(arguments.dropLast(1).toList(), receivedArguments!!.dropLast(1).toList())
            assertTrue(receivedArguments!!.last() != target.absolutePath)
            assertEquals(target.parentFile.canonicalFile, staging!!.parentFile)
            assertEquals(target.extension, staging!!.extension)
            assertEquals("new complete output", target.readText())
            assertFalse(staging!!.exists())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun firstExecutionSweepsOnlyOwnOrphanFilesAndPreservesOtherEntries() {
        val directory = createTempDirectory()
        try {
            val prefix = ".mornye-ffmpeg-${BuildConfig.APPLICATION_ID}-"
            val ownOrphan = File(directory, "$prefix${UUID.randomUUID()}.flac")
                .also { it.writeText("orphan") }
            val foreignFile = File(directory, ".mornye-ffmpeg-foreign-${UUID.randomUUID()}.flac")
                .also { it.writeText("foreign") }
            val malformedFile = File(directory, "${prefix}not-a-uuid.flac")
                .also { it.writeText("malformed") }
            val preservedDirectory = File(directory, "$prefix${UUID.randomUUID()}.flac")
            check(preservedDirectory.mkdir()) { "failed to create preserved directory" }
            val directoryContent = File(preservedDirectory, "content.txt")
                .also { it.writeText("directory content") }
            val symlinkTarget = File(directory, "symlink-target.txt")
                .also { it.writeText("symlink content") }
            val symlink = File(directory, "$prefix${UUID.randomUUID()}.flac")
            Files.createSymbolicLink(symlink.toPath(), symlinkTarget.toPath())

            val target = File(directory, "output.flac")
            val command = CoreFFmpegCommand("sweep", arrayOf("convert", target.absolutePath), target.absolutePath)
            var staged: File? = null
            val result = executeCoreFFmpegCommand(command, cancelled = { false }) { arguments, _ ->
                assertFalse(ownOrphan.exists())
                assertEquals("foreign", foreignFile.readText())
                assertEquals("malformed", malformedFile.readText())
                assertTrue(preservedDirectory.isDirectory)
                assertEquals("directory content", directoryContent.readText())
                assertTrue(Files.isSymbolicLink(symlink.toPath()))
                assertEquals("symlink content", symlink.readText())

                staged = File(arguments.last()).also { it.writeText("published") }
                true to "converted"
            }

            assertTrue(result.first)
            assertEquals("published", target.readText())
            assertFalse(staged!!.exists())
            assertFalse(ownOrphan.exists())
            assertEquals("foreign", foreignFile.readText())
            assertEquals("malformed", malformedFile.readText())
            assertEquals("directory content", directoryContent.readText())
            assertTrue(Files.isSymbolicLink(symlink.toPath()))
            assertEquals("symlink content", symlink.readText())
        } finally {
            directory.deleteRecursively()
        }
    }

    @Test
    fun overlappingExecutionsPreserveLiveStagingAndPublishBothOutputs() {
        val directory = createTempDirectory()
        try {
            val firstTarget = File(directory, "first.flac")
            val secondTarget = File(directory, "second.flac")
            val firstCommand = CoreFFmpegCommand(
                "first",
                arrayOf("convert-first", firstTarget.absolutePath),
                firstTarget.absolutePath,
            )
            val secondCommand = CoreFFmpegCommand(
                "second",
                arrayOf("convert-second", secondTarget.absolutePath),
                secondTarget.absolutePath,
            )
            var firstStage: File? = null
            var secondStage: File? = null

            val result = executeCoreFFmpegCommand(firstCommand, cancelled = { false }) { arguments, _ ->
                firstStage = File(arguments.last()).also { it.writeText("first staged") }
                val nestedResult = executeCoreFFmpegCommand(secondCommand, cancelled = { false }) { nestedArguments, _ ->
                    secondStage = File(nestedArguments.last())
                    assertTrue(firstStage!!.exists())
                    assertEquals("first staged", firstStage!!.readText())
                    secondStage!!.writeText("second published")
                    true to "second complete"
                }

                assertTrue(nestedResult.first)
                assertEquals("second published", secondTarget.readText())
                assertTrue(firstStage!!.exists())
                assertEquals("first staged", firstStage!!.readText())
                true to "first complete"
            }

            assertTrue(result.first)
            assertEquals("first staged", firstTarget.readText())
            assertEquals("second published", secondTarget.readText())
            assertFalse(firstStage!!.exists())
            assertFalse(secondStage!!.exists())
        } finally {
            directory.deleteRecursively()
        }
    }
}
