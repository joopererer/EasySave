package com.james.easysave

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

/**
 * The creator list orders Chinese names by the system collation (pinyin for a
 * Chinese locale). The keys are compared as plain strings in Dart, so the
 * encoded form must order exactly like the raw collation keys.
 */
class NativeCollationTest {

    private val locale = Locale.CHINA

    private fun keys(vararg names: String): List<String> =
        NativeCollation.keysFor(names.toList(), locale)

    @Test
    fun chineseNamesSortByPinyin() {
        val names = listOf("张三", "李四", "王五", "阿部")
        val sorted = names.sortedWith { a, b ->
            val ka = NativeCollation.keysFor(listOf(a), locale).first()
            val kb = NativeCollation.keysFor(listOf(b), locale).first()
            ka.compareTo(kb)
        }
        assertEquals(listOf("阿部", "李四", "王五", "张三"), sorted)
    }

    @Test
    fun encodedKeysCompareLikeTheRawCollation() {
        val latin = keys("alice", "Bob", "carol")
        assertEquals(3, latin.size)
        assertTrue(latin.all { it.isNotEmpty() && it.length % 2 == 0 })
        assertTrue(latin[0] < latin[1])
        assertTrue(latin[1] < latin[2])

        val chinese = keys("张三", "李四")
        assertTrue(chinese[1] < chinese[0])
    }

    @Test
    fun equalNamesProduceEqualKeysAndEmptyInputIsEmpty() {
        assertEquals(keys("张三"), keys("张三"))
        assertEquals(emptyList<String>(), NativeCollation.keysFor(emptyList(), locale))
        assertEquals(2, keys("a", "b").size)
    }
}