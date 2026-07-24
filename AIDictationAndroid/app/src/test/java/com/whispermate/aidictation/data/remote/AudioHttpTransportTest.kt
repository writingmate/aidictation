package com.whispermate.aidictation.data.remote

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AudioHttpTransportTest {
    private lateinit var server: MockWebServer
    private lateinit var client: OkHttpClient

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        client = OkHttpClient.Builder()
            .readTimeout(500, TimeUnit.MILLISECONDS)
            .callTimeout(2, TimeUnit.SECONDS)
            .build()
    }

    @After
    fun tearDown() {
        client.dispatcher.cancelAll()
        client.connectionPool.evictAll()
        server.shutdown()
    }

    @Test
    fun permanent400IsClassifiedBeforeStalledErrorBodyAndNeverRetried() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(400)
                .setBody("diagnostic body that must not be drained")
                .setBodyDelay(2, TimeUnit.SECONDS)
        )
        server.enqueue(MockResponse().setResponseCode(200).setBody("wrong retry"))

        val engine = SequentialAudioRecognitionEngine(
            transport = AudioLeafTransport<String> { execute(it).body },
            splitter = AudioLeafSplitter { _, _ -> null },
            recoveryDelay = RecoveryDelay { }
        )
        val startedAt = System.nanoTime()
        val error = failure { engine.recognize(listOf("root")) { _, _ -> true } }
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

        assertTrue(error is AudioHttpException)
        assertEquals(400, (error as AudioHttpException).statusCode)
        assertEquals(1, server.requestCount)
        assertTrue("error classification waited for body: ${elapsedMillis}ms", elapsedMillis < 1_000)
    }

    @Test
    fun disconnectedErrorBodyKeepsKnownStatusClassification() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(422)
                .setBody("validation diagnostics")
                .setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
        )

        val error = failure { execute("disconnecting-error") }

        assertTrue(error is AudioHttpException)
        assertEquals(422, (error as AudioHttpException).statusCode)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun retryAfterIsCapturedFromHeadersWithoutDraining429Body() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(429)
                .addHeader("Retry-After", "30")
                .setBody("slow diagnostic")
                .setBodyDelay(2, TimeUnit.SECONDS)
        )

        val error = failure { execute("rate-limited") }

        assertTrue(error is AudioHttpException)
        assertEquals(10_000L, (error as AudioHttpException).retryAfterMillis)
    }

    @Test
    fun stalled500BodiesRetryFromStatusAndThirdCompleteResponseWins() = runBlocking {
        repeat(2) {
            server.enqueue(
                MockResponse()
                    .setResponseCode(500)
                    .setBody("server diagnostic that must not be drained")
                    .setBodyDelay(2, TimeUnit.SECONDS)
            )
        }
        server.enqueue(MockResponse().setResponseCode(200).setBody("recovered transcript"))
        val engine = SequentialAudioRecognitionEngine(
            transport = AudioLeafTransport<String> { execute(it).body },
            splitter = AudioLeafSplitter { _, _ -> null },
            recoveryDelay = RecoveryDelay { }
        )
        val startedAt = System.nanoTime()

        val result = engine.recognize(listOf("server-error")) { _, _ -> true }
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - startedAt)

        assertEquals("recovered transcript", result)
        assertEquals(3, server.requestCount)
        assertTrue("500 handling waited for diagnostic bodies: ${elapsedMillis}ms", elapsedMillis < 1_000)
    }

    @Test
    fun rejected413SplitsOnlyThatLeafWithoutReplayingIt() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(413)
                .setBody("oversized diagnostic")
                .setBodyDelay(2, TimeUnit.SECONDS)
        )
        server.enqueue(MockResponse().setResponseCode(200).setBody("left"))
        server.enqueue(MockResponse().setResponseCode(200).setBody("right"))

        val engine = SequentialAudioRecognitionEngine(
            transport = AudioLeafTransport<String> { execute(it).body },
            splitter = AudioLeafSplitter { leaf, _ ->
                if (leaf == "root") listOf("left", "right") else null
            },
            recoveryDelay = RecoveryDelay { }
        )

        assertEquals("left right", engine.recognize(listOf("root")) { _, _ -> true })
        assertEquals(3, server.requestCount)
        assertEquals("/root", server.takeRequest().path)
        assertEquals("/left", server.takeRequest().path)
        assertEquals("/right", server.takeRequest().path)
    }

    @Test
    fun complete200BodyIsReturnedAndDisconnected200BodyIsTransportFailure() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "text/plain")
                .setBody("complete transcript")
        )
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .setBody("incomplete transcript")
                .setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
        )

        val complete = execute("complete")
        val disconnected = failure { execute("disconnected-success") }

        assertEquals("complete transcript", complete.body)
        assertEquals("text/plain", complete.contentType)
        assertTrue(disconnected is IOException)
    }

    @Test
    fun fullyReceivedMalformed200IsOneShot() = runBlocking {
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "application/json")
                .setBody("""{"unexpected":"shape"}""")
        )
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "application/json")
                .setBody("""{"text":"wrong retry"}""")
        )
        val engine = SequentialAudioRecognitionEngine(
            transport = AudioLeafTransport<String> { leaf ->
                val response = execute(leaf)
                TranscriptionClient.parseTranscriptionText(response.body, response.contentType)
            },
            splitter = AudioLeafSplitter { _, _ -> null },
            recoveryDelay = RecoveryDelay { }
        )

        val error = failure { engine.recognize(listOf("malformed")) { _, _ -> true } }

        assertTrue(error is AudioMalformedResponseException)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun disconnected200BodyRetriesTwiceAndThirdCompleteBodyWins() = runBlocking {
        repeat(2) {
            server.enqueue(
                MockResponse()
                    .setResponseCode(200)
                    .addHeader("Content-Type", "text/plain")
                    .setBody("incomplete ".repeat(4_096))
                    .setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
            )
        }
        server.enqueue(
            MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "text/plain")
                .setBody("complete after reconnect")
        )
        val engine = SequentialAudioRecognitionEngine(
            transport = AudioLeafTransport<String> { execute(it).body },
            splitter = AudioLeafSplitter { _, _ -> null },
            recoveryDelay = RecoveryDelay { }
        )

        assertEquals(
            "complete after reconnect",
            engine.recognize(listOf("disconnected")) { _, _ -> true }
        )
        assertEquals(3, server.requestCount)
    }

    private suspend fun execute(leaf: String): CompleteAudioHttpResponse {
        val request = Request.Builder().url(server.url("/$leaf")).build()
        return executeAudioHttpRequest(client, request)
    }

    private suspend fun failure(block: suspend () -> Unit): Throwable {
        try {
            block()
            fail("Expected failure")
        } catch (error: Throwable) {
            return error
        }
        throw AssertionError("unreachable")
    }
}
