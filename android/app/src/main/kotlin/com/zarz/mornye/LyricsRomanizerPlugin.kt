package com.zarz.mornye

import android.os.Build
import android.os.Handler
import android.os.Looper
import com.atilika.kuromoji.ipadic.Tokenizer
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Japanese lyric readings. Ported from PixelPlayerOSS (GPL-3.0)
 * `MultiLangRomanizer.romanizeJapanese`
 * (app/src/main/java/com/lostf1sh/pixelplayeross/utils/LyricsUtils.kt):
 * Kuromoji supplies each token's katakana reading, particles are read the way
 * they are spoken, and ICU turns the katakana into lowercase Latin.
 */
class LyricsRomanizerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "romanizeJapanese") {
            result.notImplemented()
            return
        }
        val lines = call.argument<List<String>>("lines")
        if (lines == null) {
            result.error("bad_args", "lines is required", null)
            return
        }
        // The dictionary load and tokenizing are too slow for the main thread.
        worker.execute {
            val readings = lines.map { romanizeJapanese(it) }
            main.post { result.success(readings) }
        }
    }

    private companion object {
        const val CHANNEL = "com.zarz.mornye/lyrics_romanizer"

        val worker = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "lyrics-romanizer").apply { isDaemon = true }
        }

        val kuromoji: Tokenizer? by lazy {
            try {
                Thread.currentThread().contextClassLoader =
                    LyricsRomanizerPlugin::class.java.classLoader
                Tokenizer()
            } catch (_: Throwable) {
                null
            }
        }

        fun romanizeJapanese(text: String): String? {
            val tokenizer = kuromoji ?: return null
            return try {
                val tokens = tokenizer.tokenize(text)

                // Reading, part of speech level 1, part of speech level 2.
                val readings = mutableListOf<Triple<String, String, String>>()
                var i = 0
                while (i < tokens.size) {
                    val token = tokens[i]
                    val next = tokens.getOrNull(i + 1)

                    when {
                        token.surface == "一" && next?.surface == "人" -> {
                            readings += Triple("ヒトリ", "名詞", "一般"); i += 2; continue
                        }
                        token.surface == "二" && next?.surface == "人" -> {
                            readings += Triple("フタリ", "名詞", "一般"); i += 2; continue
                        }
                        token.surface == "今日" -> {
                            readings += Triple("キョウ", "名詞", "一般"); i++; continue
                        }
                        token.surface == "明日" -> {
                            readings += Triple("アシタ", "名詞", "一般"); i++; continue
                        }
                        token.surface == "昨日" -> {
                            readings += Triple("キノウ", "名詞", "一般"); i++; continue
                        }
                    }

                    val pos1 = token.partOfSpeechLevel1 ?: ""
                    val pos2 = token.partOfSpeechLevel2 ?: ""
                    val surface = token.surface ?: ""
                    val reading = token.reading?.takeIf { it.isNotBlank() && it != "*" }

                    val kata = when {
                        pos1 == "助詞" -> when (surface) {
                            "は" -> "ワ"
                            "へ" -> "エ"
                            "を" -> "オ"
                            else -> reading ?: surface
                        }
                        else -> reading ?: surface
                    }
                    readings += Triple(kata, pos1, pos2)
                    i++
                }

                val kataBuf = StringBuilder()
                readings.forEachIndexed { idx, (kata, pos1, pos2) ->
                    val prevKata = readings.getOrNull(idx - 1)?.first ?: ""
                    val prevEndsWithSokuon = prevKata.endsWith("ッ") || prevKata.endsWith("っ")
                    val noSpace = idx == 0 ||
                        prevEndsWithSokuon ||
                        pos1 == "助動詞" ||
                        pos2 == "接尾" ||
                        pos1 == "記号" ||
                        pos2 == "非自立"
                    if (!noSpace) kataBuf.append(" ")
                    kataBuf.append(kata)
                }

                val katakanaText = kataBuf.toString().replace("\\s+".toRegex(), " ").trim()

                val latin = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    android.icu.text.Transliterator
                        .getInstance("Katakana-Latin; Lower")
                        .transliterate(katakanaText)
                } else {
                    katakanaText
                }

                latin
                    .replace(Regex("n(?=[bp])"), "m")
                    .replace(Regex("\\s+"), " ")
                    .trim()
            } catch (_: Throwable) {
                null
            }
        }
    }
}
