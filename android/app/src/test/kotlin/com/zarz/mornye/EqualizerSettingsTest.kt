package com.zarz.mornye

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EqualizerSettingsTest {
    private val frequencies = listOf(60.0, 230.0, 910.0, 3600.0, 14000.0)

    private fun configuration(vararg extra: Pair<String, Any?>): Map<String, Any?> = mapOf(
        "enabled" to true,
        "gains" to listOf(1.0, -2.0, 0.0, 3.5, 24.0),
        "frequencies" to frequencies,
    ) + extra

    @Test
    fun disabledConfigurationTurnsTheEffectOff() {
        assertNull(EqualizerSettings.parse(mapOf("enabled" to false)))
        assertNull(EqualizerSettings.parse(emptyMap()))
    }

    @Test
    fun parsesBandsAndDefaults() {
        val settings = requireNotNull(EqualizerSettings.parse(configuration()))
        assertEquals(listOf(1f, -2f, 0f, 3.5f, 24f), settings.gains)
        assertEquals(0f, settings.inputGain)
        assertEquals(0f, settings.balance)
        assertFalse(settings.compressor)
        assertEquals(10f, settings.attack)
        assertEquals(150f, settings.release)
        assertEquals(-18f, settings.threshold)
        assertEquals(3f, settings.ratio)
        assertTrue(settings.limiter)
        val cutoffs = settings.cutoffs()
        assertEquals(5, cutoffs.size)
        assertEquals(kotlin.math.sqrt(60f * 230f), cutoffs[0], 0.001f)
        assertEquals(24000f, cutoffs.last())
    }

    @Test
    fun clampsOptionalValuesAndFoldsBalanceIntoChannelGain() {
        val settings = requireNotNull(EqualizerSettings.parse(configuration(
            "inputGain" to 30.0,
            "balance" to 0.5,
            "compressor" to true,
            "attack" to 0.0,
            "ratio" to 50.0,
            "limiter" to false,
        )))
        assertEquals(12f, settings.inputGain)
        assertEquals(1f, settings.attack)
        assertEquals(20f, settings.ratio)
        assertTrue(settings.compressor)
        assertFalse(settings.limiter)
        assertEquals(12f + 20f * kotlin.math.log10(0.5f), settings.channelGain(0), 0.001f)
        assertEquals(12f, settings.channelGain(1), 0.001f)
    }

    @Test
    fun rejectsInvalidBands() {
        val invalid = listOf(
            mapOf("enabled" to true, "frequencies" to frequencies),
            mapOf("enabled" to true, "gains" to listOf(0.0, 0.0, 0.0, 0.0, 0.0)),
            configuration("gains" to listOf(0.0, 0.0, 0.0, 0.0)),
            configuration("gains" to listOf(0.0, 0.0, 0.0, 0.0, 25.0)),
            configuration("frequencies" to listOf(60.0, 230.0, 230.0, 3600.0, 14000.0)),
            configuration("frequencies" to listOf(0.0, 230.0, 910.0, 3600.0, 14000.0)),
            configuration("balance" to Double.NaN),
        )
        for (data in invalid) {
            val failure = runCatching { EqualizerSettings.parse(data) }.exceptionOrNull()
            assertTrue("Expected rejection of $data", failure is IllegalArgumentException || failure is IllegalStateException)
        }
    }
}
