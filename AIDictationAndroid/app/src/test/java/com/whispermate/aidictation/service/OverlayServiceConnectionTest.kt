package com.whispermate.aidictation.service

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayServiceConnectionTest {

    private fun connection() = OverlayServiceConnection(shortcutMaxWaitMs = 5_000L)

    @Test
    fun `a first connection is not stale`() {
        assertFalse(connection().connect())
    }

    @Test
    fun `connecting again without a disconnect reports the old connection as stale`() {
        // Its windows went with it, so the service must forget them and end its dictation.
        val connection = connection()
        connection.connect()
        assertTrue(connection.connect())
    }

    @Test
    fun `a reconnect after a disconnect starts clean`() {
        val connection = connection()
        connection.connect()
        connection.disconnect()
        assertFalse(connection.isConnected)
        assertFalse(connection.connect())
        assertTrue(connection.isConnected)
    }

    @Test
    fun `the shortcut starts at once while connected`() {
        val connection = connection()
        connection.connect()
        assertTrue(connection.requestShortcut(nowMs = 1_000L))
        assertFalse(connection.takePendingShortcut(nowMs = 1_000L))
    }

    @Test
    fun `a shortcut before the connection waits for it and starts once`() {
        val connection = connection()
        assertFalse(connection.requestShortcut(nowMs = 1_000L))
        connection.connect()
        assertTrue(connection.takePendingShortcut(nowMs = 2_000L))
        assertFalse(connection.takePendingShortcut(nowMs = 2_000L))
    }

    @Test
    fun `a shortcut that waited too long is dropped`() {
        val connection = connection()
        connection.requestShortcut(nowMs = 1_000L)
        connection.connect()
        assertFalse(connection.takePendingShortcut(nowMs = 6_001L))
    }

    @Test
    fun `a shortcut is not taken without a connection`() {
        val connection = connection()
        connection.requestShortcut(nowMs = 1_000L)
        assertFalse(connection.takePendingShortcut(nowMs = 1_000L))
        connection.connect()
        assertTrue(connection.takePendingShortcut(nowMs = 1_500L))
    }

    @Test
    fun `a disconnect drops a waiting shortcut`() {
        val connection = connection()
        connection.requestShortcut(nowMs = 1_000L)
        connection.disconnect()
        connection.connect()
        assertFalse(connection.takePendingShortcut(nowMs = 1_500L))
    }
}
