package com.whispermate.aidictation.service

/**
 * Whether the overlay service holds a live accessibility connection, plus a dictation
 * shortcut that arrived without one.
 *
 * The shortcut reaches the service through startService, which can create or reach an
 * instance the system has not connected yet (for example while it rebinds after the
 * process restarted). Without a connection there is no window to draw the bubble in, so
 * the request waits for the connection instead of being dropped. A request older than
 * [shortcutMaxWaitMs] is dropped: dictation starting long after the tap would surprise.
 *
 * Overlay windows belong to the connection: when it ends the system removes them, so the
 * service must forget them and end the dictation they showed. A second connect without a
 * disconnect in between reports the old connection as stale for the same reason.
 */
internal class OverlayServiceConnection(private val shortcutMaxWaitMs: Long) {
    var isConnected = false
        private set

    private var pendingShortcutAtMs: Long? = null

    /** Returns true when a previous connection was never torn down. */
    fun connect(): Boolean {
        val stale = isConnected
        isConnected = true
        return stale
    }

    fun disconnect() {
        isConnected = false
        pendingShortcutAtMs = null
    }

    /** Returns true to start dictation now, false when it waits for the connection. */
    fun requestShortcut(nowMs: Long): Boolean {
        if (isConnected) return true
        pendingShortcutAtMs = nowMs
        return false
    }

    /** Returns true once for a request that arrived before the connection and is still fresh. */
    fun takePendingShortcut(nowMs: Long): Boolean {
        if (!isConnected) return false
        val requestedAt = pendingShortcutAtMs ?: return false
        pendingShortcutAtMs = null
        return nowMs - requestedAt <= shortcutMaxWaitMs
    }
}
