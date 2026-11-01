package com.zarz.mornye

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImpellerCompatibilityTest {
    @Test
    fun knownRasterCrashUsesFallbackOnTheReportedDeviceAndAndroidVersion() {
        assertTrue(hasKnownImpellerRasterCrash(35, "Xiaomi", "25053PC47I"))
        assertTrue(hasKnownImpellerRasterCrash(35, "XIAOMI", "25053pc47i"))
    }

    @Test
    fun samsungVulkanCrashUsesFallbackOnTheReportedDeviceAndAndroidVersion() {
        assertTrue(hasKnownImpellerRasterCrash(36, "samsung", "SM-S711B"))
        assertTrue(hasKnownImpellerRasterCrash(36, "SAMSUNG", "sm-s711b"))
    }

    @Test
    fun sonySnapshotCrashUsesFallbackOnTheReportedDeviceAndAndroidVersion() {
        assertTrue(hasKnownImpellerRasterCrash(33, "Sony", "SOG04"))
        assertTrue(hasKnownImpellerRasterCrash(33, "SONY", "sog04"))
    }

    @Test
    fun sonyFallbackDoesNotIncludeOtherDevicesOrAndroidVersions() {
        assertFalse(hasKnownImpellerRasterCrash(32, "Sony", "SOG04"))
        assertFalse(hasKnownImpellerRasterCrash(34, "Sony", "SOG04"))
        assertFalse(hasKnownImpellerRasterCrash(33, "Sony", "SOG05"))
        assertFalse(hasKnownImpellerRasterCrash(33, "Other", "SOG04"))
    }

    @Test
    fun samsungFallbackDoesNotIncludeOtherDevicesOrAndroidVersions() {
        assertFalse(hasKnownImpellerRasterCrash(35, "samsung", "SM-S711B"))
        assertFalse(hasKnownImpellerRasterCrash(37, "samsung", "SM-S711B"))
        assertFalse(hasKnownImpellerRasterCrash(36, "samsung", "SM-S711U"))
        assertFalse(hasKnownImpellerRasterCrash(36, "samsung", "SM-S911B"))
        assertFalse(hasKnownImpellerRasterCrash(36, "Other", "SM-S711B"))
    }

    @Test
    fun otherDevicesAndAndroidVersionsKeepTheirExistingRendererPolicy() {
        assertFalse(hasKnownImpellerRasterCrash(34, "Xiaomi", "25053PC47I"))
        assertFalse(hasKnownImpellerRasterCrash(36, "Xiaomi", "25053PC47I"))
        assertFalse(hasKnownImpellerRasterCrash(37, "Xiaomi", "25053PC47I"))
        assertFalse(hasKnownImpellerRasterCrash(35, "Xiaomi", "25053PC47G"))
        assertFalse(hasKnownImpellerRasterCrash(35, "Other", "25053PC47I"))
    }
}
