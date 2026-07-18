package com.whispermate.aidictation.data.repository

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProfileMutationContractTest {
    private val accountA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    @Test
    fun `word count increment is atomic and bound to the expected account`() {
        val mutation = incrementWordCountMutation(accountA, wordsToAdd = 42)

        assertEquals("increment_monthly_word_count_for_session", mutation.functionName)
        assertEquals(
            mapOf(
                "expected_user_id" to accountA,
                "words_to_add" to 42
            ),
            mutation.parameters
        )
    }

    @Test
    fun `referral code creation is bound to the expected account`() {
        val mutation = ensureReferralCodeMutation(accountA)

        assertEquals("ensure_referral_code_for_session", mutation.functionName)
        assertEquals(mapOf("expected_user_id" to accountA), mutation.parameters)
    }

    @Test
    fun `referral redemption keeps the expected account beside the invite code`() {
        val mutation = redeemReferralCodeMutation(accountA, code = "FRIEND42")

        assertEquals("redeem_referral_code_for_session", mutation.functionName)
        assertEquals(
            mapOf(
                "code" to "FRIEND42",
                "expected_user_id" to accountA
            ),
            mutation.parameters
        )
    }

    @Test
    fun `profile results must belong to the expected account`() {
        assertTrue(profileMutationResultMatchesExpectedUser(accountA, accountA.uppercase()))
        assertFalse(
            profileMutationResultMatchesExpectedUser(
                accountA,
                "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            )
        )
        assertFalse(profileMutationResultMatchesExpectedUser(accountA, ""))
    }

    @Test
    fun `profile mutation snapshots require the original active identity`() {
        assertTrue(
            profileMutationSnapshotMatchesActiveIdentity(
                expectedUserID = accountA,
                expectedGeneration = 7,
                currentGeneration = 7,
                currentUserID = accountA.uppercase()
            )
        )
        assertFalse(
            profileMutationSnapshotMatchesActiveIdentity(
                expectedUserID = accountA,
                expectedGeneration = 7,
                currentGeneration = 8,
                currentUserID = accountA
            )
        )
        assertFalse(
            profileMutationSnapshotMatchesActiveIdentity(
                expectedUserID = accountA,
                expectedGeneration = 7,
                currentGeneration = 7,
                currentUserID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            )
        )
        assertFalse(
            profileMutationSnapshotMatchesActiveIdentity(
                expectedUserID = accountA,
                expectedGeneration = 7,
                currentGeneration = 7,
                currentUserID = null
            )
        )
    }

    @Test
    fun `profile mutation gate serializes delayed responses`() = runBlocking {
        val gate = ProfileMutationGate()
        val firstEntered = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()

        val first = async {
            gate.run {
                events += "first-start"
                firstEntered.complete(Unit)
                delay(30)
                events += "first-end"
            }
        }
        firstEntered.await()
        val second = async {
            gate.run {
                events += "second"
            }
        }

        first.await()
        second.await()
        assertEquals(listOf("first-start", "first-end", "second"), events)
    }

    @Test
    fun `queued profile mutation does not start after the identity changes`() = runBlocking {
        val gate = ProfileMutationGate()
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val generation = AtomicLong(7)
        val secondBodyStarted = AtomicBoolean(false)

        val first = async {
            gate.run {
                firstEntered.complete(Unit)
                releaseFirst.await()
            }
        }
        firstEntered.await()
        val second = async {
            gate.run {
                val isCurrent = profileMutationSnapshotMatchesActiveIdentity(
                    expectedUserID = accountA,
                    expectedGeneration = 7,
                    currentGeneration = generation.get(),
                    currentUserID = accountA
                )
                if (!isCurrent) return@run false
                secondBodyStarted.set(true)
                true
            }
        }

        generation.set(8)
        releaseFirst.complete(Unit)
        first.await()

        assertFalse(second.await())
        assertFalse(secondBodyStarted.get())
    }

    @Test
    fun `profile refresh runs after mutations and sees their committed state`() = runBlocking {
        val gate = ProfileMutationGate()
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        val databaseCount = AtomicLong(0)
        val displayedCount = AtomicLong(-1)

        val mutation = async {
            gate.run {
                firstEntered.complete(Unit)
                releaseFirst.await()
                databaseCount.addAndGet(42)
            }
        }
        firstEntered.await()
        val refresh = async {
            gate.run {
                displayedCount.set(databaseCount.get())
            }
        }

        releaseFirst.complete(Unit)
        mutation.await()
        refresh.await()

        assertEquals(42, databaseCount.get())
        assertEquals(42, displayedCount.get())
    }
}
