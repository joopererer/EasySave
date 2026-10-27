package com.james.easysave

/**
 * Parses a user-typed item selection such as `1,3,5-8` into zero-based
 * indices. Pure Kotlin so it can be unit-tested without Android.
 *
 * Numbers are one-based (what the user sees on the post). Accepts ASCII and
 * full-width digits, `, ， 、 ; ；` and whitespace as separators, and
 * `- － – — ~ ～` as range separators. Reversed ranges (`8-5`) are accepted.
 */
object IndexSpec {
    data class Result(
        /** Sorted, de-duplicated, zero-based indices inside `0 until total`. */
        val indices: List<Int>,
        /** True when a number or range end fell outside `1..total`. */
        val outOfRange: Boolean,
        /** True when a token could not be understood at all. */
        val invalid: Boolean,
    )

    fun parse(text: String, total: Int): Result {
        val normalized = normalize(text)
        val out = sortedSetOf<Int>()
        var outOfRange = false
        var invalid = false
        for (token in normalized.split(',')) {
            if (token.isEmpty()) continue
            val parts = token.split('-')
            val nums = parts.map { it.toIntOrNull() }
            when {
                parts.size == 1 && nums[0] != null -> {
                    val n = nums[0]!!
                    if (n in 1..total) out.add(n - 1) else outOfRange = true
                }
                parts.size == 2 && nums[0] != null && nums[1] != null -> {
                    val a = minOf(nums[0]!!, nums[1]!!)
                    val b = maxOf(nums[0]!!, nums[1]!!)
                    if (a < 1 || b > total) outOfRange = true
                    for (n in maxOf(a, 1)..minOf(b, total)) out.add(n - 1)
                }
                else -> invalid = true
            }
        }
        return Result(out.toList(), outOfRange, invalid)
    }

    private fun normalize(text: String): String {
        val sb = StringBuilder(text.length)
        for (c in text) {
            when {
                c in '０'..'９' -> sb.append('0' + (c - '０'))
                c == '，' || c == '、' || c == ';' || c == '；' || c.isWhitespace() -> sb.append(',')
                c == '－' || c == '–' || c == '—' || c == '~' || c == '～' || c == '‐' -> sb.append('-')
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }
}
