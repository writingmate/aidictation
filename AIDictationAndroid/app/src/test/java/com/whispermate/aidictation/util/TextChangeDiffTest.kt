package com.whispermate.aidictation.util

import com.whispermate.aidictation.util.TextChangeDiff.Kind
import com.whispermate.aidictation.util.TextChangeDiff.Segment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TextChangeDiffTest {

    private fun reconstruct(segments: List<Segment>, keep: Kind): String =
        segments.filter { it.kind == Kind.Equal || it.kind == keep }.joinToString("") { it.text }

    private fun assertRoundTrips(original: String, transformed: String) {
        val segments = TextChangeDiff.diff(original, transformed)
        assertEquals(original, reconstruct(segments, Kind.Deleted))
        assertEquals(transformed, reconstruct(segments, Kind.Inserted))
        // Adjacent segments never share a kind.
        segments.zipWithNext().forEach { (a, b) -> assertTrue(a.kind != b.kind) }
    }

    @Test
    fun `identical text is a single equal segment with no changes`() {
        val segments = TextChangeDiff.diff("hello world", "hello world")
        assertEquals(listOf(Segment(Kind.Equal, "hello world")), segments)
        assertFalse(TextChangeDiff.hasChanges(segments))
    }

    @Test
    fun `a corrected word is shown as deletion then insertion`() {
        val segments = TextChangeDiff.diff("I has a dog.", "I have a dog.")
        assertEquals(
            listOf(
                Segment(Kind.Equal, "I "),
                Segment(Kind.Deleted, "has"),
                Segment(Kind.Inserted, "have"),
                Segment(Kind.Equal, " a dog.")
            ),
            segments
        )
        assertTrue(TextChangeDiff.hasChanges(segments))
    }

    @Test
    fun `insertions and deletions reconstruct both texts`() {
        assertRoundTrips("the quick fox", "the quick brown fox")
        assertRoundTrips("the quick brown fox", "the quick fox")
        assertRoundTrips("its raining, isnt it", "It's raining, isn't it?")
        assertRoundTrips("", "something new")
        assertRoundTrips("all gone", "")
    }

    @Test
    fun `punctuation changes are isolated from the surrounding words`() {
        val segments = TextChangeDiff.diff("hello world", "hello, world!")
        assertEquals(
            listOf(
                Segment(Kind.Equal, "hello"),
                Segment(Kind.Inserted, ","),
                Segment(Kind.Equal, " world"),
                Segment(Kind.Inserted, "!")
            ),
            segments
        )
    }

    @Test
    fun `a rewrite that replaces everything still round trips`() {
        val original = "please send me the report by friday thanks"
        val transformed = "Could you send me the report by Friday? Thank you."
        assertRoundTrips(original, transformed)
        assertTrue(TextChangeDiff.hasChanges(TextChangeDiff.diff(original, transformed)))
    }

    @Test
    fun `very long inputs fall back to a wholesale replacement`() {
        val original = (1..700).joinToString(" ") { "a$it" }
        val transformed = (1..700).joinToString(" ") { "b$it" }
        val segments = TextChangeDiff.diff(original, transformed)
        assertEquals(
            listOf(Segment(Kind.Deleted, original), Segment(Kind.Inserted, transformed)),
            segments
        )
    }
}
