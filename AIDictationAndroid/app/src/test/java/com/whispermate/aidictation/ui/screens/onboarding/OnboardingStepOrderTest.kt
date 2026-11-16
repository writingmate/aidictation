package com.whispermate.aidictation.ui.screens.onboarding

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class OnboardingStepOrderTest {
    @Test
    fun ratingStepComesStraightAfterADemoThatProducedText() {
        val steps = onboardingStepOrder(demoProducedText = true, signInAvailable = true, paywallAvailable = true)

        assertEquals(steps.indexOf(OnboardingStep.ButtonDemo) + 1, steps.indexOf(OnboardingStep.Review))
        assertEquals(OnboardingStep.Paywall, steps.last())
    }

    @Test
    fun nobodyIsAskedToRateBeforeADictationHasWorked() {
        val steps = onboardingStepOrder(demoProducedText = false, signInAvailable = true, paywallAvailable = true)

        assertFalse(OnboardingStep.Review in steps)
    }

    @Test
    fun aDemoResultOnlyAddsAStepAfterTheDemo() {
        val before = onboardingStepOrder(demoProducedText = false, signInAvailable = false, paywallAvailable = false)
        val after = onboardingStepOrder(demoProducedText = true, signInAvailable = false, paywallAvailable = false)
        val demoIndex = before.indexOf(OnboardingStep.ButtonDemo)

        // The user is on the demo step when the result lands; nothing at or before it may move.
        assertEquals(before.subList(0, demoIndex + 1), after.subList(0, demoIndex + 1))
        assertEquals(before, after - OnboardingStep.Review)
    }

    @Test
    fun countsTheWordsOfTheDemoDictation() {
        assertEquals(4, dictatedWordCount("  Hello there,  how\nare "))
        assertEquals(1, dictatedWordCount("Hello"))
        assertEquals(0, dictatedWordCount("   "))
    }
}
