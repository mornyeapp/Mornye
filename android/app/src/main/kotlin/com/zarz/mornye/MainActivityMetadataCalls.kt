package com.zarz.mornye

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

internal suspend fun MainActivity.handleRewriteSplitArtistTags(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val artist = call.argument<String>("artist") ?: ""
    val albumArtist = call.argument<String>("album_artist") ?: ""
    val response = withContext(Dispatchers.IO) {
        if (filePath.startsWith("content://")) {
            val uri = Uri.parse(filePath)
            val tempPath = copyUriToTemp(coreBackend, uri, ".flac")
                ?: return@withContext errorJson("Failed to copy SAF file to temp")
            try {
                val raw = coreBackend.rewriteSplitArtistTags(tempPath, artist, albumArtist)
                val obj = JSONObject(raw)
                if (!obj.optBoolean("success", false)) {
                    return@withContext raw
                }

                if (!writeUriFromPath(uri, tempPath)) {
                    return@withContext errorJson("Failed to write rewritten tags back to SAF file")
                }

                obj.put("file_path", filePath)
                obj.toString()
            } catch (e: Exception) {
                errorJson("Failed to rewrite split artist tags in SAF file: ${e.message}")
            } finally {
                try {
                    File(tempPath).delete()
                } catch (_: Exception) {}
            }
        } else {
            coreBackend.rewriteSplitArtistTags(filePath, artist, albumArtist)
        }
    }
    result.success(response)
}

internal suspend fun Context.handleReadFileMetadata(
    call: MethodCall,
    result: MethodChannel.Result,
    coreBackend: CoreBackend,
) {
    val filePath = call.argument<String>("file_path") ?: ""
    val displayName = call.argument<String>("display_name") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            if (filePath.startsWith("content://")) {
                readCompleteMetadataFromUri(coreBackend, Uri.parse(filePath), displayName)
                    ?.toString() ?: errorJson("Failed to read SAF metadata")
            } else {
                coreBackend.readFileMetadata(filePath, displayName)
            }
        } catch (e: Exception) {
            errorJson(e.message ?: "Failed to read metadata")
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleCheckHiResAuthenticity(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val optionsJson = call.argument<String>("options_json") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            if (filePath.startsWith("content://")) {
                checkHiResAuthenticityFromUri(coreBackend, Uri.parse(filePath), optionsJson)
                    ?.toString()
                    ?: errorJson("Failed to read SAF audio file")
            } else {
                coreBackend.checkHiResAuthenticity(filePath, optionsJson)
            }
        } catch (e: Exception) {
            errorJson(e.message ?: "Hi-Res check failed")
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleEditFileMetadata(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val metadataJson = call.argument<String>("metadata_json") ?: "{}"
    val response = withContext(Dispatchers.IO) {
        try {
            if (filePath.startsWith("content://")) {
                val uri = Uri.parse(filePath)
                val tempPath = copyUriToTemp(coreBackend, uri)
                    ?: return@withContext """{"error":"Failed to copy SAF file to temp"}"""
                try {
                    val raw = coreBackend.editFileMetadata(tempPath, metadataJson)
                    val obj = JSONObject(raw)
                    val method = obj.optString("method", "")
                    if (method == "ffmpeg") {
                        // MP3/Opus: Dart needs to FFmpeg the temp file, then call writeTempToSaf
                        obj.put("temp_path", tempPath)
                        obj.put("saf_uri", filePath)
                        return@withContext obj.toString()
                        // Note: temp file NOT deleted here - Dart will clean up after FFmpeg + writeTempToSaf
                    }
                    if (!writeUriFromPath(uri, tempPath)) {
                        try { File(tempPath).delete() } catch (_: Exception) {}
                        return@withContext """{"error":"Failed to write metadata back to SAF file"}"""
                    }
                    try { File(tempPath).delete() } catch (_: Exception) {}
                    raw
                } catch (e: Exception) {
                    try { File(tempPath).delete() } catch (_: Exception) {}
                    throw e
                }
            } else {
                coreBackend.editFileMetadata(filePath, metadataJson)
            }
        } catch (e: Exception) {
            android.util.Log.e("Mornye", "editFileMetadata failed: ${e.message}", e)
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleWriteM4AFreeformTags(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val metadataJson = call.argument<String>("metadata_json") ?: "{}"
    val response = withContext(Dispatchers.IO) {
        try {
            coreBackend.writeM4aFreeformTags(filePath, metadataJson)
        } catch (e: Exception) {
            android.util.Log.e("Mornye", "writeM4AFreeformTags failed: ${e.message}", e)
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleEnsureAC4Config(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val sourcePath = call.argument<String>("source_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            coreBackend.ensureAc4Config(filePath, sourcePath)
        } catch (e: Exception) {
            android.util.Log.e("Mornye", "ensureAC4Config failed: ${e.message}", e)
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleWriteAC4Metadata(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val metadataJson = call.argument<String>("metadata_json") ?: "{}"
    val coverPath = call.argument<String>("cover_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            coreBackend.writeAc4Metadata(filePath, metadataJson, coverPath)
        } catch (e: Exception) {
            android.util.Log.e("Mornye", "writeAC4Metadata failed: ${e.message}", e)
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleDownloadCoverToFile(call: MethodCall, result: MethodChannel.Result) {
    val coverUrl = call.argument<String>("cover_url") ?: ""
    val outputPath = call.argument<String>("output_path") ?: ""
    val maxDimension = call.argument<Number>("max_dimension")
        ?.toLong()
        ?.coerceAtLeast(0L)
        ?: 0L
    val response = withContext(Dispatchers.IO) {
        var temporaryCover: File? = null
        try {
            val destination = if (outputPath.isBlank()) {
                coreBackend.createTemporaryMediaFile(
                    this@handleDownloadCoverToFile,
                    "cover_",
                    ".jpg",
                ).also { temporaryCover = it }.absolutePath
            } else {
                outputPath
            }
            coreBackend.downloadCoverToFileSized(
                coverUrl,
                destination,
                maxDimension
            )
            JSONObject()
                .put("success", true)
                .put("file_path", destination)
                .toString()
        } catch (e: Exception) {
            temporaryCover?.delete()
            """{"success":false,"error":"${e.message?.replace("\"", "'")}"}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleExtractCoverToFile(call: MethodCall, result: MethodChannel.Result) {
    val audioPath = call.argument<String>("audio_path") ?: ""
    val outputPath = call.argument<String>("output_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            if (audioPath.startsWith("content://")) {
                extractCoverFromUri(coreBackend, Uri.parse(audioPath), outputPath)
                """{"success":true}"""
            } else {
                coreBackend.extractCoverToFile(audioPath, outputPath)
                """{"success":true}"""
            }
        } catch (e: Exception) {
            """{"success":false,"error":"${e.message?.replace("\"", "'")}"}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleReEnrichFile(call: MethodCall, result: MethodChannel.Result) {
    val requestJson = call.argument<String>("request_json") ?: "{}"
    val response = withContext(Dispatchers.IO) {
        try {
            val reqObj = JSONObject(requestJson)
            val filePath = reqObj.optString("file_path", "")

            // Preview only resolves online metadata; it does not need
            // a full SAF document copy and never writes the source.
            if (filePath.startsWith("content://") && !reqObj.optBoolean("preview_only", false)) {
                val uri = Uri.parse(filePath)
                val tempPath = copyUriToTemp(coreBackend, uri)
                    ?: return@withContext """{"error":"Failed to copy SAF file to temp"}"""
                var retainedForFfmpeg = false
                try {
                    reqObj.put("file_path", tempPath)
                    val raw = coreBackend.reEnrichFile(reqObj.toString())
                    val obj = JSONObject(raw)

                    if (obj.has("error")) {
                        return@withContext raw
                    }

                    val method = obj.optString("method", "")
                    if (method == "ffmpeg") {
                        // MP3/Opus: Dart handles FFmpeg on temp file, then writes back
                        obj.put("temp_path", tempPath)
                        obj.put("saf_uri", filePath)
                        retainedForFfmpeg = true
                        return@withContext obj.toString()
                        // Dart cleans up after FFmpeg + writeTempToSaf.
                    }

                    if (!writeUriFromPath(uri, tempPath)) {
                        return@withContext """{"error":"Failed to write enriched metadata back to SAF file"}"""
                    }
                    if (obj.optBoolean("write_external_lrc", false) &&
                        !writeSafSidecarLrc(uri, obj.optString("lyrics", ""))) {
                        return@withContext errorJson(
                            "Metadata was saved, but the LRC lyrics file could not be updated"
                        )
                    }
                    raw
                } finally {
                    if (!retainedForFfmpeg) {
                        try { File(tempPath).delete() } catch (_: Exception) {}
                    }
                }
            } else {
                coreBackend.reEnrichFile(requestJson)
            }
        } catch (e: Exception) {
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleRunPostProcessingV2(call: MethodCall, result: MethodChannel.Result) {
    val inputJson = call.argument<String>("input") ?: ""
    val metadataJson = call.argument<String>("metadata") ?: ""
    val response = withContext(Dispatchers.IO) {
        val inputObj = if (inputJson.isNotBlank()) JSONObject(inputJson) else JSONObject()
        val uriStr = inputObj.optString("uri", "")
        val pathStr = inputObj.optString("path", "")
        val effectiveUri = when {
            uriStr.startsWith("content://") -> uriStr
            pathStr.startsWith("content://") -> pathStr
            else -> ""
        }

        if (effectiveUri.isNotBlank()) {
            runPostProcessingSafV2(coreBackend, effectiveUri, metadataJson, inputObj.optString("item_id", ""))
        } else {
            if (pathStr.isNotBlank()) {
                inputObj.put("name", File(pathStr).name)
                inputObj.put("is_saf", false)
            }
            coreBackend.runPostProcessing(inputObj.toString(), metadataJson)
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleReadAudioMetadata(call: MethodCall, result: MethodChannel.Result) {
    val filePath = call.argument<String>("file_path") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            if (filePath.startsWith("content://")) {
                val uri = Uri.parse(filePath)
                val metadata = readAudioMetadataFromUri(
                    coreBackend,
                    uri,
                    coverCacheKey = buildLibraryCoverCacheKey(filePath, 0),
                )
                    ?: return@withContext """{"error":"Failed to read SAF audio metadata"}"""
                metadata.put("filePath", filePath)
                metadata.toString()
            } else {
                coreBackend.readAudioMetadata(filePath, "", "")
            }
        } catch (e: Exception) {
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}

internal suspend fun MainActivity.handleParseCueSheet(call: MethodCall, result: MethodChannel.Result) {
    val cuePath = call.argument<String>("cue_path") ?: ""
    val audioDir = call.argument<String>("audio_dir") ?: ""
    val response = withContext(Dispatchers.IO) {
        try {
            if (cuePath.startsWith("content://")) {
                val uri = Uri.parse(cuePath)
                val tempCuePath = copyUriToTemp(coreBackend, uri, ".cue")
                    ?: return@withContext """{"error":"Failed to copy CUE file to temp"}"""
                try {
                    val audioFileName = extractCueAudioFileName(tempCuePath)

                    val parentDir = safParentDir(uri)
                    val audioDoc = if (parentDir != null) {
                        val cueName = try {
                            DocumentFile.fromSingleUri(this@handleParseCueSheet, uri)?.name ?: ""
                        } catch (_: Exception) { "" }
                        findSafCueAudioSibling(this@handleParseCueSheet, parentDir, cueName, audioFileName)
                    } else {
                        null
                    }

                    if (audioDoc == null || !audioDoc.isFile) {
                        return@withContext JSONObject()
                            .put("error", "Audio file not found for CUE sheet")
                            .toString()
                    }

                    // Preview parses the CUE text only; the selected audio
                    // stays in SAF instead of copying a whole album to cache.
                    val resultJson = coreBackend.parseCueSheetWithResolvedAudio(
                        tempCuePath,
                        audioDoc.uri.toString(),
                    )
                    JSONObject(resultJson)
                        .put("cue_path", cuePath)
                        .toString()
                } finally {
                    try { File(tempCuePath).delete() } catch (_: Exception) {}
                }
            } else {
                coreBackend.parseCueSheet(cuePath, audioDir)
            }
        } catch (e: Exception) {
            """{"error":${org.json.JSONObject.quote(e.message ?: "unknown")}}"""
        }
    }
    result.success(response)
}
