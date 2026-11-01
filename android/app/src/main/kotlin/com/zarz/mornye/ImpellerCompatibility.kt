package com.zarz.mornye

import android.os.Build
import java.util.Locale

// Device detection that decides whether Flutter starts with Impeller disabled.
// MainActivity.ImpellerAwareFlutterFragment stays nested in MainActivity
// because proguard-rules.pro keeps it by that name.

private const val SAFE_API_FOR_IMPELLER = 29

private val PROBLEMATIC_GPU_PATTERNS = listOf(
    "adreno (tm) 3",
    "adreno (tm) 4",
    "mali-4",
    "mali-t6",
    "mali-t7",
    "powervr sgx",
    "powervr ge8320",
    "vivante",
    "gc1000",
    "gc2000",
    "gc4000",
    "gc5000",
    "gc7000",
    "gc8000",
    "gc820",
    "gc880",
)

private val PROBLEMATIC_CHIPSETS = listOf(
    "mt6762",
    "mt6765",
    "mt8768",
    "mp0873",
    "msm8974",
    "msm8226",
    "msm8926",
    "apq8084",
)

// Sony Walkman / audio players report MANUFACTURER "SonyAudio" (distinct
// from Xperia phones, which use "Sony"). They ship legacy Vivante GPUs
// whose drivers crash in glLinkProgram with Impeller shaders, and the GL
// renderer string is unavailable when shell args are built, so match on
// the manufacturer instead.
private val PROBLEMATIC_MANUFACTURERS = listOf(
    "sonyaudio",
)

private val PROBLEMATIC_MODELS = listOf(
    "sm-t220",
    "sm-t225",
    "hammerhead",
)

internal fun hasKnownImpellerRasterCrash(sdk: Int, manufacturer: String, model: String): Boolean =
    (sdk == 35 && manufacturer.equals("xiaomi", ignoreCase = true) &&
        model.equals("25053PC47I", ignoreCase = true)) ||
        (sdk == 36 && manufacturer.equals("samsung", ignoreCase = true) &&
            model.equals("SM-S711B", ignoreCase = true)) ||
        (sdk == 33 && manufacturer.equals("sony", ignoreCase = true) &&
            model.equals("SOG04", ignoreCase = true))

internal fun flutterRendererShellArgs(): Array<String> =
    if (shouldDisableImpeller()) arrayOf("--enable-impeller=false") else emptyArray()

internal fun shouldDisableImpeller(): Boolean {
    val hardware = Build.HARDWARE.lowercase(Locale.ROOT)
    val board = Build.BOARD.lowercase(Locale.ROOT)
    val model = Build.MODEL.lowercase(Locale.ROOT)
    val device = Build.DEVICE.lowercase(Locale.ROOT)
    val manufacturer = Build.MANUFACTURER.lowercase(Locale.ROOT)

    // Reported Impeller crashes in SaveLayer, Vulkan submission and GLES snapshots.
    // Keep these workarounds scoped to the reported device and Android version.
    if (hasKnownImpellerRasterCrash(Build.VERSION.SDK_INT, manufacturer, model)) {
        android.util.Log.i("Mornye", "Using Skia for a known Impeller raster crash on $model")
        return true
    }

    for (problematicManufacturer in PROBLEMATIC_MANUFACTURERS) {
        if (manufacturer.contains(problematicManufacturer)) {
            android.util.Log.i("Mornye", "Matched problematic manufacturer: $problematicManufacturer")
            return true
        }
    }

    for (problematicModel in PROBLEMATIC_MODELS) {
        if (model.contains(problematicModel) || device.contains(problematicModel)) {
            android.util.Log.i("Mornye", "Matched problematic model: $problematicModel")
            return true
        }
    }

    for (chipset in PROBLEMATIC_CHIPSETS) {
        if (hardware.contains(chipset) || board.contains(chipset)) {
            android.util.Log.i("Mornye", "Matched problematic chipset: $chipset")
            return true
        }
    }

    if (Build.VERSION.SDK_INT < SAFE_API_FOR_IMPELLER) {
        val gpuRenderer = getGpuRenderer().lowercase(Locale.ROOT)

        for (pattern in PROBLEMATIC_GPU_PATTERNS) {
            if (gpuRenderer.contains(pattern)) {
                android.util.Log.i("Mornye", "Matched problematic GPU on old Android: $pattern")
                return true
            }
        }

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            android.util.Log.i("Mornye", "Android < 8.0, using Skia for safety")
            return true
        }
    }

    val gpuRenderer = getGpuRenderer().lowercase(Locale.ROOT)
    for (pattern in PROBLEMATIC_GPU_PATTERNS) {
        if (gpuRenderer.contains(pattern)) {
            android.util.Log.i("Mornye", "Matched problematic GPU: $pattern")
            return true
        }
    }

    return false
}

/**
 * Note: This may return empty on some devices before OpenGL context is created.
 */
private fun getGpuRenderer(): String {
    return try {
        android.opengl.GLES20.glGetString(android.opengl.GLES20.GL_RENDERER) ?: ""
    } catch (e: Exception) {
        ""
    }
}
