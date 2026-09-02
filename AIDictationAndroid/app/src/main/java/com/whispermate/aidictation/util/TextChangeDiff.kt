package com.whispermate.aidictation.util

/**
 * Word-level difference between an original text and its transformed version, used to
 * show what a selection command (Fix grammar, Rewrite with AI) wants to change before
 * the user accepts it.
 */
object TextChangeDiff {

    enum class Kind { Equal, Inserted, Deleted }

    data class Segment(val kind: Kind, val text: String)

    // Words (with inner apostrophes and hyphens), runs of whitespace, and single
    // punctuation marks are the units a reader thinks of as "a change".
    private val TOKEN = Regex("""\s+|[\p{L}\p{N}_'’-]+|[^\s\p{L}\p{N}_'’-]""")

    /** Beyond this the quadratic alignment is not worth it; show a wholesale replacement. */
    private const val MAX_TOKENS = 600

    /**
     * Returns segments in reading order. Concatenating the Equal and Deleted segments
     * yields [original]; concatenating the Equal and Inserted segments yields
     * [transformed]. Where text is replaced, the deletion precedes the insertion.
     */
    fun diff(original: String, transformed: String): List<Segment> {
        if (original == transformed) {
            return if (original.isEmpty()) emptyList() else listOf(Segment(Kind.Equal, original))
        }
        val a = tokenize(original)
        val b = tokenize(transformed)
        if (a.size > MAX_TOKENS || b.size > MAX_TOKENS) {
            return merge(
                listOfNotNull(
                    Segment(Kind.Deleted, original).takeIf { original.isNotEmpty() },
                    Segment(Kind.Inserted, transformed).takeIf { transformed.isNotEmpty() }
                )
            )
        }

        // Longest common subsequence over tokens.
        val lcs = Array(a.size + 1) { IntArray(b.size + 1) }
        for (i in a.indices.reversed()) {
            for (j in b.indices.reversed()) {
                lcs[i][j] = if (a[i] == b[j]) {
                    lcs[i + 1][j + 1] + 1
                } else {
                    maxOf(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        val segments = ArrayList<Segment>()
        var i = 0
        var j = 0
        while (i < a.size && j < b.size) {
            when {
                a[i] == b[j] -> {
                    segments += Segment(Kind.Equal, a[i])
                    i++
                    j++
                }
                // On a tie prefer the insertion: it keeps shared tokens (typically the
                // whitespace after a corrected word) out of the change run.
                lcs[i + 1][j] > lcs[i][j + 1] -> {
                    segments += Segment(Kind.Deleted, a[i])
                    i++
                }
                else -> {
                    segments += Segment(Kind.Inserted, b[j])
                    j++
                }
            }
        }
        while (i < a.size) segments += Segment(Kind.Deleted, a[i++])
        while (j < b.size) segments += Segment(Kind.Inserted, b[j++])

        return merge(orderReplacements(segments))
    }

    fun hasChanges(segments: List<Segment>): Boolean = segments.any { it.kind != Kind.Equal }

    private fun tokenize(text: String): List<String> = TOKEN.findAll(text).map { it.value }.toList()

    /** Within a run of non-equal tokens, put all deletions before all insertions. */
    private fun orderReplacements(segments: List<Segment>): List<Segment> {
        val ordered = ArrayList<Segment>(segments.size)
        val deleted = ArrayList<Segment>()
        val inserted = ArrayList<Segment>()
        fun flush() {
            ordered += deleted
            ordered += inserted
            deleted.clear()
            inserted.clear()
        }
        for (segment in segments) {
            when (segment.kind) {
                Kind.Equal -> {
                    flush()
                    ordered += segment
                }
                Kind.Deleted -> deleted += segment
                Kind.Inserted -> inserted += segment
            }
        }
        flush()
        return ordered
    }

    private fun merge(segments: List<Segment>): List<Segment> {
        val merged = ArrayList<Segment>()
        for (segment in segments) {
            val last = merged.lastOrNull()
            if (last != null && last.kind == segment.kind) {
                merged[merged.lastIndex] = Segment(last.kind, last.text + segment.text)
            } else {
                merged += segment
            }
        }
        return merged
    }
}
