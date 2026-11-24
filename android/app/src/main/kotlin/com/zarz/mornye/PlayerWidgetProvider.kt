package com.zarz.mornye

import android.app.ActivityOptions
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.os.Bundle
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.RemoteViews
import androidx.core.graphics.ColorUtils
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Native launcher rendering; audio remains in the app's shared Flutter engine. */
class PlayerWidgetProvider : AppWidgetProvider() {
    override fun onEnabled(context: Context) {
        PlayerWidgetBridge.installedWidgetsChanged(context)
    }

    override fun onDisabled(context: Context) {
        PlayerWidgetBridge.installedWidgetsChanged(context, 0)
    }

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        val appContext = context.applicationContext
        val copy = ids.copyOf()
        widgetExecutor.execute {
            try {
                update(appContext, copy)
            } finally {
                pending.finish()
            }
        }
        PlayerWidgetBridge.installedWidgetsChanged(context)
    }

    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        val pending = goAsync()
        val appContext = context.applicationContext
        widgetExecutor.execute {
            try {
                update(appContext, intArrayOf(id))
            } finally {
                pending.finish()
            }
        }
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val editor = preferences(context).edit()
        ids.forEach { editor.remove("theme_$it").remove("artist_$it") }
        editor.apply()
        val count = AppWidgetManager.getInstance(context)
            .getAppWidgetIds(ComponentName(context, PlayerWidgetProvider::class.java))
            .count { it !in ids }
        PlayerWidgetBridge.installedWidgetsChanged(context, count)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION) return
        val command = intent.getStringExtra(COMMAND) ?: return
        if (command !in setOf("toggle", "next", "previous")) return
        val pending = goAsync()
        if (!PlayerWidgetBridge.command(command) { pending.finish() }) {
            // A killed process has no audio engine. A widget click may launch
            // the activity to restore the queue and then execute this command.
            val options = if (Build.VERSION.SDK_INT >= 34) {
                ActivityOptions.makeBasic().apply {
                    // Preserve the launch privilege from this widget tap when
                    // the sender is a receiver rather than a visible activity.
                    setPendingIntentBackgroundActivityStartMode(
                        ActivityOptions.MODE_BACKGROUND_ACTIVITY_START_ALLOWED,
                    )
                }.toBundle()
            } else null
            try {
                launchIntent(context, command).send(context, 0, null, null, null, null, options)
            } catch (error: PendingIntent.CanceledException) {
                Log.w("PlayerWidget", "Widget launch was cancelled", error)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION = "com.zarz.mornye.PLAYER_WIDGET_ACTION"
        const val COMMAND = "player_widget_command"
        private const val DISABLED_ALPHA = 0.38f
        // One thread renders every widget update, so an older frame never lands last.
        internal val widgetExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "MornyePlayerWidget").apply { isDaemon = true }
        }
        fun preferences(context: Context) = context.getSharedPreferences("player_widget", Context.MODE_PRIVATE)

        fun installedCount(context: Context): Int = AppWidgetManager.getInstance(context)
            .getAppWidgetIds(ComponentName(context, PlayerWidgetProvider::class.java)).size

        fun launchIntent(context: Context, command: String): PendingIntent = PendingIntent.getActivity(
            context, 8100 + command.hashCode(),
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                putExtra(COMMAND, command)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        fun update(context: Context, ids: IntArray? = null) {
            val manager = AppWidgetManager.getInstance(context)
            val widgets = ids ?: manager.getAppWidgetIds(ComponentName(context, PlayerWidgetProvider::class.java))
            if (widgets.isEmpty()) return
            val prefs = preferences(context)
            val state = state(context)
            val cover = cover(context, state)
            for (id in widgets) {
                val options = manager.getAppWidgetOptions(id)
                val width = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 280)
                val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 150)
                manager.updateAppWidget(id, render(
                    context, state, cover, prefs.getString("theme_$id", "artwork"),
                    prefs.getBoolean("artist_$id", true), width, height,
                ))
            }
            cover?.recycle()
        }

        fun state(context: Context): JSONObject =
            runCatching { JSONObject(preferences(context).getString("state", "{}")!!) }.getOrDefault(JSONObject())

        fun cover(context: Context, state: JSONObject): Bitmap? = if (state.optString("artworkKey").isNotEmpty()) {
            BitmapFactory.decodeFile(File(context.filesDir, "player-widget-cover.png").path)
        } else null

        /** Builds one widget instance; the configuration screen reuses it as a live preview. */
        fun render(
            context: Context, state: JSONObject, cover: Bitmap?, theme: String?,
            showArtist: Boolean, width: Int, height: Int,
        ): RemoteViews {
            val active = state.optBoolean("canPlay")
            val playing = state.optBoolean("playing")
            val density = context.resources.displayMetrics.density
            val corner = if (Build.VERSION.SDK_INT >= 31) {
                context.resources.getDimension(android.R.dimen.system_app_widget_background_radius)
            } else 28 * density
            // The wide row needs room for the cover and all three controls;
            // shorter sizes without that width use the full-bleed cover.
            val wide = width >= 340 && height < 240
            val compact = !wide && (width < 200 || height < 240)
            val layout = when {
                wide -> R.layout.widget_player_wide
                compact -> R.layout.widget_player_compact
                else -> R.layout.widget_player
            }
            val views = RemoteViews(context.packageName, layout)
            val colors = palette(context, theme, seed(state))
            views.setInt(R.id.player_widget_background, "setColorFilter", colors.container)
            views.setTextViewText(R.id.player_widget_title, state.optString("title").ifEmpty { context.getString(R.string.player_widget_name) })
            views.setTextViewText(R.id.player_widget_artist, if (active) state.optString("artist") else context.getString(R.string.player_widget_empty))
            views.setViewVisibility(R.id.player_widget_artist, if (showArtist) View.VISIBLE else View.GONE)
            // Over a full-bleed cover the text sits on a dark scrim.
            val overCover = compact && cover != null
            views.setTextColor(R.id.player_widget_title, if (overCover) Color.WHITE else colors.onContainer)
            views.setTextColor(R.id.player_widget_artist, if (overCover) 0xd9ffffff.toInt() else colors.onContainerVariant)
            views.setImageViewBitmap(R.id.player_widget_art, when {
                compact -> filledCover(context, cover, width, height, density, corner, colors)
                cover != null -> roundedCover(cover)
                else -> placeholder(context, colors)
            })

            fun bind(root: Int, shape: Int, icon: Int, iconRes: Int, fill: Int, tint: Int, command: String) {
                val enabled = active && when (command) {
                    "previous" -> state.optBoolean("canPrevious")
                    "next" -> state.optBoolean("canNext")
                    else -> true
                }
                views.setInt(shape, "setColorFilter", fill)
                views.setImageViewResource(icon, iconRes)
                views.setInt(icon, "setColorFilter", tint)
                // A widget may set a view's alpha only from Android 12; before
                // it the call fails the whole widget, so the two images of
                // the button dim instead.
                if (Build.VERSION.SDK_INT >= 31) {
                    views.setFloat(root, "setAlpha", if (enabled) 1f else DISABLED_ALPHA)
                } else {
                    val alpha = if (enabled) 255 else (DISABLED_ALPHA * 255).toInt()
                    views.setInt(shape, "setImageAlpha", alpha)
                    views.setInt(icon, "setImageAlpha", alpha)
                }
                views.setBoolean(root, "setEnabled", enabled)
                views.setOnClickPendingIntent(root, PendingIntent.getBroadcast(
                    context, 8200 + command.hashCode(),
                    Intent(context, PlayerWidgetProvider::class.java).setAction(ACTION).putExtra(COMMAND, command),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                ))
            }
            views.setImageViewResource(R.id.player_widget_play_shape, if (playing) R.drawable.widget_shape_squircle else R.drawable.widget_shape_pill)
            bind(R.id.player_widget_play, R.id.player_widget_play_shape, R.id.player_widget_play_icon,
                if (playing) R.drawable.ic_widget_pause else R.drawable.ic_widget_play, colors.primary, colors.onPrimary, "toggle")
            if (!compact) {
                bind(R.id.player_widget_previous, R.id.player_widget_previous_shape, R.id.player_widget_previous_icon,
                    R.drawable.ic_widget_previous, colors.tonal, colors.onTonal, "previous")
                bind(R.id.player_widget_next, R.id.player_widget_next_shape, R.id.player_widget_next_icon,
                    R.drawable.ic_widget_next, colors.tonal, colors.onTonal, "next")
            }
            views.setContentDescription(R.id.player_widget_play, context.getString(if (playing) R.string.player_widget_pause else R.string.player_widget_play))
            views.setOnClickPendingIntent(R.id.player_widget_root, launchIntent(context, "open"))
            return views
        }

        fun seed(state: JSONObject) = state.optLong("background", 0xff292433).toInt()

        class Palette(
            val container: Int,
            val onContainer: Int,
            val onContainerVariant: Int,
            val primary: Int,
            val onPrimary: Int,
            val tonal: Int,
            val onTonal: Int,
        )

        /**
         * Light and Dark follow the wallpaper's dynamic colours where the
         * system provides them. Artwork derives tonal roles from the cover.
         */
        fun palette(context: Context, theme: String?, seed: Int): Palette {
            if (theme != "light" && theme != "dark") return tonalPalette(seed, dark = true)
            val dark = theme == "dark"
            if (Build.VERSION.SDK_INT < 31) return tonalPalette(0xff6750a4.toInt(), dark)
            fun c(id: Int) = context.getColor(id)
            return if (dark) Palette(
                c(android.R.color.system_neutral1_900), c(android.R.color.system_neutral1_50),
                c(android.R.color.system_neutral2_200), c(android.R.color.system_accent1_200),
                c(android.R.color.system_accent1_800), c(android.R.color.system_accent2_700),
                c(android.R.color.system_accent2_100),
            ) else Palette(
                c(android.R.color.system_neutral1_50), c(android.R.color.system_neutral1_900),
                c(android.R.color.system_neutral2_700), c(android.R.color.system_accent1_600),
                c(android.R.color.system_accent1_0), c(android.R.color.system_accent2_100),
                c(android.R.color.system_accent2_900),
            )
        }

        private fun tonalPalette(seed: Int, dark: Boolean): Palette {
            val hsl = FloatArray(3)
            ColorUtils.colorToHSL(seed, hsl)
            val s = hsl[1]
            fun tone(saturation: Float, lightness: Float) =
                ColorUtils.HSLToColor(floatArrayOf(hsl[0], saturation.coerceIn(0f, 1f), lightness))
            return if (dark) Palette(
                container = tone(minOf(s, 0.42f), 0.15f),
                onContainer = tone(minOf(s, 0.12f), 0.95f),
                onContainerVariant = tone(minOf(s, 0.18f), 0.76f),
                primary = tone(s.coerceIn(0.35f, 0.75f), 0.80f),
                onPrimary = tone(minOf(s, 0.5f), 0.16f),
                tonal = tone(minOf(s, 0.38f), 0.26f),
                onTonal = tone(minOf(s, 0.3f), 0.90f),
            ) else Palette(
                container = tone(minOf(s, 0.4f), 0.96f),
                onContainer = tone(minOf(s, 0.2f), 0.11f),
                onContainerVariant = tone(minOf(s, 0.15f), 0.32f),
                primary = tone(s.coerceIn(0.3f, 0.6f), 0.42f),
                onPrimary = Color.WHITE,
                tonal = tone(minOf(s, 0.45f), 0.88f),
                onTonal = tone(minOf(s, 0.4f), 0.14f),
            )
        }

        private fun roundedCover(source: Bitmap): Bitmap {
            val size = 384
            val scaled = Bitmap.createScaledBitmap(source, size, size, true)
            val result = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            // Expressive covers use large corners: about a fifth of the side.
            val radius = size * 0.2f
            Canvas(result).drawRoundRect(0f, 0f, size.toFloat(), size.toFloat(), radius, radius, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = BitmapShader(scaled, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
            })
            if (scaled !== source) scaled.recycle()
            return result
        }

        /** The compact widget's cover fills it edge to edge under a bottom scrim. */
        private fun filledCover(
            context: Context, source: Bitmap?, width: Int, height: Int,
            density: Float, corner: Float, colors: Palette,
        ): Bitmap {
            val scale = minOf(density, 2f, 512f / maxOf(width, height, 1))
            val w = (width * scale).toInt().coerceAtLeast(1)
            val h = (height * scale).toInt().coerceAtLeast(1)
            val result = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(result)
            val radius = corner * scale / density
            if (source == null) {
                val icon = context.getDrawable(R.drawable.ic_widget_music)!!.mutate()
                icon.setTint(colors.onContainerVariant)
                val side = minOf(w, h) * 0.34f
                val left = (w - side) / 2
                val top = (h - side) / 2 - h * 0.12f
                icon.setBounds(left.toInt(), top.toInt(), (left + side).toInt(), (top + side).toInt())
                icon.draw(canvas)
                return result
            }
            val crop = minOf(source.width / w.toFloat(), source.height / h.toFloat())
            val sw = w * crop
            val sh = h * crop
            val matrix = android.graphics.Matrix().apply {
                setScale(1 / crop, 1 / crop)
                preTranslate(-(source.width - sw) / 2, -(source.height - sh) / 2)
            }
            val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG).apply {
                shader = BitmapShader(source, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP).apply { setLocalMatrix(matrix) }
            }
            canvas.drawRoundRect(0f, 0f, w.toFloat(), h.toFloat(), radius, radius, paint)
            canvas.drawRoundRect(0f, 0f, w.toFloat(), h.toFloat(), radius, radius, Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(0f, h * 0.35f, 0f, h.toFloat(), Color.TRANSPARENT, 0xcc000000.toInt(), Shader.TileMode.CLAMP)
            })
            return result
        }

        private fun placeholder(context: Context, colors: Palette): Bitmap {
            val size = 384
            val result = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(result)
            val radius = size * 0.2f
            canvas.drawRoundRect(0f, 0f, size.toFloat(), size.toFloat(), radius, radius, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = colors.tonal })
            val icon = context.getDrawable(R.drawable.ic_widget_music)!!.mutate()
            icon.setTint(colors.onTonal)
            icon.setBounds(132, 132, 252, 252)
            icon.draw(canvas)
            return result
        }
    }
}

object PlayerWidgetBridge : FlutterEngine.EngineLifecycleListener {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var ready = false
    private var pendingCommand: String? = null
    private val worker = PlayerWidgetProvider.widgetExecutor
    private val main = Handler(Looper.getMainLooper())

    fun attach(context: Context, flutterEngine: FlutterEngine) {
        if (engine !== flutterEngine) {
            engine?.removeEngineLifecycleListener(this)
            engine = flutterEngine
            flutterEngine.addEngineLifecycleListener(this)
            ready = false
        }
        val app = context.applicationContext
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.zarz.mornye/player_widget").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "ready" -> {
                        ready = true
                        result.success(null)
                        pendingCommand?.let { command(it) {} }
                        pendingCommand = null
                    }
                    "getInstalledWidgetCount" -> result.success(PlayerWidgetProvider.installedCount(app))
                    "update" -> {
                        val data = call.arguments as? Map<*, *>
                        if (data == null) { result.error("bad_state", "Missing widget state", null); return@setMethodCallHandler }
                        worker.execute {
                            try {
                                val prefs = PlayerWidgetProvider.preferences(app)
                                val bytes = data["artwork"] as? ByteArray
                                val old = JSONObject(prefs.getString("state", "{}")!!)
                                val cover = File(app.filesDir, "player-widget-cover.png")
                                if (PlayerWidgetProvider.installedCount(app) > 0 && bytes != null &&
                                    (old.optString("artworkKey") != data["artworkKey"] || !cover.isFile)) {
                                    val temp = File(app.filesDir, "player-widget-cover.tmp")
                                    temp.writeBytes(bytes)
                                    check(temp.renameTo(cover))
                                }
                                val state = JSONObject()
                                data.forEach { (key, value) -> if (key is String && key != "artwork") state.put(key, value) }
                                val serialized = state.toString()
                                if (serialized != old.toString()) prefs.edit().putString("state", serialized).commit()
                                PlayerWidgetProvider.update(app)
                                main.post { result.success(null) }
                            } catch (error: Exception) {
                                main.post { result.error("widget_update", error.message, null) }
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onPreEngineRestart() {
        ready = false
    }

    fun installedWidgetsChanged(context: Context, count: Int = PlayerWidgetProvider.installedCount(context)) {
        main.post {
            if (ready) channel?.invokeMethod("installedWidgetCountChanged", count)
        }
    }

    override fun onEngineWillDestroy() {
        ready = false
        channel = null
        pendingCommand = null
        engine = null
    }

    fun handleIntent(intent: Intent?) {
        val action = intent?.getStringExtra(PlayerWidgetProvider.COMMAND) ?: return
        intent.removeExtra(PlayerWidgetProvider.COMMAND)
        if (!command(action) {}) pendingCommand = action
    }

    fun command(action: String, completion: () -> Unit): Boolean {
        val bridge = channel ?: return false
        if (!ready) return false
        var finished = false
        fun finish() { if (!finished) { finished = true; completion() } }
        main.postDelayed({ finish() }, 8500)
        bridge.invokeMethod("command", action, object : MethodChannel.Result {
            override fun success(result: Any?) = finish()
            override fun error(code: String, message: String?, details: Any?) = finish()
            override fun notImplemented() = finish()
        })
        return true
    }
}
