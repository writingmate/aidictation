package com.whispermate.aidictation.service


/**
 * Pure ownership fences shared by the Android audio entry points. Keeping the transition rules
 * here makes timeout/cancellation races deterministic and independently testable.
 */
internal class CaptureNativeFence {
    internal enum class Phase { IDLE, STARTING, RECORDING, FINALIZING }

    private var phase = Phase.IDLE
    private var attemptToken: String? = null
    private var finalizationToken: String? = null

    @Synchronized
    fun reserveStart(token: String): Boolean {
        if (phase != Phase.IDLE) return false
        phase = Phase.STARTING
        attemptToken = token
        finalizationToken = null
        return true
    }

    @Synchronized
    fun promoteToRecording(token: String): Boolean {
        if (phase != Phase.STARTING || attemptToken != token) return false
        phase = Phase.RECORDING
        return true
    }

    @Synchronized
    fun reserveFinalization(token: String, stopToken: String): Boolean {
        if (phase != Phase.RECORDING || attemptToken != token) return false
        phase = Phase.FINALIZING
        finalizationToken = stopToken
        return true
    }

    @Synchronized
    fun acceptsFinalized(token: String, stopToken: String): Boolean {
        if (phase != Phase.FINALIZING || attemptToken != token || finalizationToken != stopToken) {
            return false
        }
        clear()
        return true
    }

    @Synchronized
    fun cancel(token: String): Boolean {
        if (phase == Phase.IDLE || attemptToken != token) return false
        clear()
        return true
    }

    @Synchronized
    fun ownsFinalization(token: String, stopToken: String): Boolean =
        phase == Phase.FINALIZING && attemptToken == token && finalizationToken == stopToken

    @Synchronized
    fun snapshot(): Phase = phase

    private fun clear() {
        phase = Phase.IDLE
        attemptToken = null
        finalizationToken = null
    }
}

internal class RetryStartFence {
    private var token: String? = null

    @Synchronized
    fun reserve(startToken: String): Boolean {
        if (token != null) return false
        token = startToken
        return true
    }

    @Synchronized
    fun install(startToken: String): Boolean {
        if (token != startToken) return false
        token = null
        return true
    }

    @Synchronized
    fun cancel(startToken: String): Boolean {
        if (token != startToken) return false
        token = null
        return true
    }
}

internal class ExclusiveRequestFence {
    private enum class Phase { ACTIVE, TERMINAL }
    private var generation = 0L
    private var activeToken: Long? = null
    private var phase: Phase? = null

    @Synchronized
    fun reserve(): Long? {
        if (activeToken != null) return null
        return (++generation).also {
            activeToken = it
            phase = Phase.ACTIVE
        }
    }

    @Synchronized
    fun owns(token: Long): Boolean = activeToken == token

    @Synchronized
    fun currentToken(): Long? = activeToken

    @Synchronized
    fun beginTerminal(token: Long): Boolean {
        if (activeToken != token || phase != Phase.ACTIVE) return false
        phase = Phase.TERMINAL
        return true
    }

    @Synchronized
    fun finish(token: Long): Boolean {
        if (activeToken != token) return false
        activeToken = null
        phase = null
        return true
    }

    @Synchronized
    fun cancelCurrent(): Long? = activeToken.also {
        activeToken = null
        phase = null
        generation += 1
    }
}

internal class ReplaceableDeliveryFence {
    internal enum class Phase { IDLE, AUDIO, DELIVERY }

    private var generation = 0L
    private var token = 0L
    private var phase = Phase.IDLE

    @Synchronized
    fun beginAudio(): Long {
        token = ++generation
        phase = Phase.AUDIO
        return token
    }

    @Synchronized
    fun beginDelivery(expectedToken: Long): Boolean {
        if (phase != Phase.AUDIO || token != expectedToken) return false
        phase = Phase.DELIVERY
        return true
    }

    @Synchronized
    fun ownsAudio(expectedToken: Long): Boolean =
        phase == Phase.AUDIO && token == expectedToken

    @Synchronized
    fun ownsDelivery(expectedToken: Long): Boolean =
        phase == Phase.DELIVERY && token == expectedToken

    @Synchronized
    fun currentToken(): Long? = token.takeIf { phase != Phase.IDLE }

    @Synchronized
    fun currentPhase(): Phase = phase

    @Synchronized
    fun finish(expectedToken: Long): Boolean {
        if (phase == Phase.IDLE || token != expectedToken) return false
        phase = Phase.IDLE
        token = 0L
        return true
    }
}

internal class AttemptEmissionFence {
    private var token: String? = null

    @Synchronized
    fun activate(attemptToken: String) {
        token = attemptToken
    }

    @Synchronized
    fun emitIfCurrent(attemptToken: String, emit: () -> Unit): Boolean {
        if (token != attemptToken) return false
        emit()
        return true
    }

    @Synchronized
    fun invalidateAndReset(reset: () -> Unit) {
        token = null
        reset()
    }
}
