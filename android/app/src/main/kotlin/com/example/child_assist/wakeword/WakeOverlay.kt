package com.example.child_assist.wakeword

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.BlurMaskFilter
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PixelFormat
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RectF
import android.graphics.Shader
import android.graphics.Typeface
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.text.TextPaint
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * The "Hey Child" waveform at the top of the screen while Child Assist itself is not on screen
 * (Home screen, another app, and the lock screen where Android allows it). Flutter decides when it
 * shows and what it says, from the real wake word state; this only draws it.
 *
 * Needs "Display over other apps" (optional; without it nothing is shown and the wake word's
 * notification is the fallback). It never takes touches or focus, and it shows only the state
 * ("I'm listening…", "Thinking…"), never what was asked or answered, so nothing private appears
 * above the lock screen. It hides itself if Flutter stops updating it.
 */
object WakeOverlay {
    private val main = Handler(Looper.getMainLooper())
    private var view: WakeOverlayView? = null

    /** If Flutter goes quiet (e.g. the app was killed mid-question), the overlay does not linger. */
    private const val STALE_MS = 30_000L
    private val hideWhenStale = Runnable { hide() }

    fun canShow(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.M || Settings.canDrawOverlays(context)

    /** Shows (or updates) the overlay. False if Android does not allow it. */
    fun show(context: Context, phase: String, title: String, hint: String?): Boolean {
        val app = context.applicationContext
        if (!canShow(app)) return false
        main.removeCallbacks(hideWhenStale)
        main.postDelayed(hideWhenStale, STALE_MS)
        view?.let {
            it.update(phase, title, hint)
            return true
        }
        val overlay = WakeOverlayView(app).apply { update(phase, title, hint) }
        return try {
            windowManager(app).addView(overlay, layoutParams(app, overlay))
            view = overlay
            WakeLog.d("overlay shown")
            true
        } catch (e: RuntimeException) {
            // BadTokenException / SecurityException: the permission was just withdrawn.
            WakeLog.w("overlay refused: ${e.javaClass.simpleName}")
            false
        }
    }

    fun hide() {
        main.removeCallbacks(hideWhenStale)
        val overlay = view ?: return
        view = null
        try {
            windowManager(overlay.context).removeViewImmediate(overlay)
            WakeLog.d("overlay hidden")
        } catch (e: RuntimeException) {
            WakeLog.w("overlay hide failed: ${e.javaClass.simpleName}")
        }
    }

    private fun windowManager(context: Context) = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager

    @SuppressLint("InternalInsetResource", "DiscouragedApi")
    private fun layoutParams(context: Context, overlay: WakeOverlayView): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val params = WindowManager.LayoutParams(
            overlay.windowWidth,
            overlay.windowHeight,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        )
        params.gravity = Gravity.TOP or Gravity.START
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            params.layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        // Centred on the front camera when Android reports its cutout; otherwise in the status bar.
        val screenWidth = context.resources.displayMetrics.widthPixels
        var centerX = screenWidth / 2f
        var centerY: Float
        val statusBarId = context.resources.getIdentifier("status_bar_height", "dimen", "android")
        val statusBar = if (statusBarId > 0) context.resources.getDimensionPixelSize(statusBarId) else 0
        centerY = if (statusBar > 0) statusBar / 2f else overlay.rowHeight / 2f
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val cutout = windowManager(context).currentWindowMetrics.windowInsets.displayCutout
            val top = cutout?.boundingRectTop
            if (top != null && !top.isEmpty) {
                centerX = top.exactCenterX()
                centerY = top.exactCenterY()
                overlay.cutoutWidth = top.width().toFloat()
            }
        }
        params.x = (centerX - overlay.windowWidth / 2f).toInt().coerceIn(0, max(0, screenWidth - overlay.windowWidth))
        params.y = max(0, (centerY - overlay.rowHeight / 2f).toInt())
        return params
    }
}

/** Draws the pill (growing into a card) with the same five-colour wave as the app. */
private class WakeOverlayView(context: Context) : View(context) {
    private val density = resources.displayMetrics.density
    private fun dp(value: Float) = value * density

    val rowHeight = dp(40f).toInt()
    val windowWidth = min(resources.displayMetrics.widthPixels - dp(32f).toInt(), dp(380f).toInt())
    val windowHeight = rowHeight + dp(76f).toInt()
    var cutoutWidth = 0f

    private var phase = "listening"
    private var title = ""
    private var hint: String? = null

    private var time = 1.3f
    private var amplitude = 0f
    private var expand = 0f
    private var lastFrame = 0L
    private val still = Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f

    private val colors = intArrayOf(
        0xFF22D3EE.toInt(), // cyan
        0xFF3B82F6.toInt(), // electric blue
        0xFF6366F1.toInt(), // indigo
        0xFF8B5CF6.toInt(), // violet
        0xFFEC4899.toInt(), // pink
    )
    private val frequency = floatArrayOf(1.5f, 2.2f, 1.15f, 1.9f, 1.35f)
    private val speed = floatArrayOf(1.0f, 1.35f, 0.8f, 1.6f, 1.15f)
    private val offset = floatArrayOf(0f, 1.1f, 2.3f, 3.6f, 4.7f)
    private val scale = floatArrayOf(0.9f, 0.72f, 1.0f, 0.82f, 0.66f)

    private val background = Paint(Paint.ANTI_ALIAS_FLAG)
    private val border = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f)
        color = Color.argb(20, 255, 255, 255)
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN) }
    private val glow = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN)
        maskFilter = BlurMaskFilter(dp(4f), BlurMaskFilter.Blur.NORMAL)
    }
    private val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = dp(16f)
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
        textAlign = Paint.Align.CENTER
    }
    private val hintPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.argb(200, 255, 255, 255)
        textSize = dp(13.5f)
        textAlign = Paint.Align.CENTER
    }
    private val path = Path()
    private val card = RectF()

    init {
        // BlurMaskFilter needs software drawing for this small view.
        setLayerType(LAYER_TYPE_SOFTWARE, null)
    }

    fun update(phase: String, title: String, hint: String?) {
        this.phase = phase
        this.title = title
        this.hint = hint
        if (still) {
            amplitude = target()
            expand = 1f
        }
        invalidate()
    }

    private fun target() = when (phase) {
        "wakeWordDetected" -> 0.85f
        "listening" -> 0.3f
        "processing" -> 0.42f
        "speaking" -> 0.6f
        "error" -> 0.08f
        else -> 0.16f
    }

    private fun phaseSpeed() = when (phase) {
        "wakeWordDetected", "speaking" -> 2.0f
        "listening" -> 1.6f
        "processing" -> 2.8f
        "error" -> 0.4f
        else -> 0.7f
    }

    /** A regular rhythm for phases with no audio level; it does not claim to follow a voice. */
    private fun modulation() = when (phase) {
        "processing" -> 0.7f + 0.3f * sin(time * 1.7f)
        "speaking" -> 0.72f + 0.28f * sin(time * 2.6f) * kotlin.math.cos(time * 1.1f)
        else -> 1f
    }

    override fun onDraw(canvas: Canvas) {
        if (!still) step()
        val w = width.toFloat()
        val pillWidth = min(w, max(cutoutWidth + dp(112f), dp(150f)))
        val cardWidth = pillWidth + (w - pillWidth) * expand
        val cardHeight = rowHeight + (windowHeight - rowHeight) * expand
        val left = (w - cardWidth) / 2f
        val radius = rowHeight / 2f + (dp(28f) - rowHeight / 2f) * expand
        card.set(left, 0f, left + cardWidth, cardHeight)

        background.shader = LinearGradient(
            card.left, card.top, card.right, card.bottom,
            intArrayOf(0xF20A0F2C.toInt(), 0xF2141443.toInt(), 0xF2231A55.toInt()),
            null, Shader.TileMode.CLAMP,
        )
        canvas.drawRoundRect(card, radius, radius, background)
        canvas.drawRoundRect(card, radius, radius, border)

        val save = canvas.save()
        canvas.clipRect(card.left + dp(10f), 0f, card.right - dp(10f), rowHeight.toFloat())
        drawWave(canvas, card.left + dp(10f), card.right - dp(10f), rowHeight / 2f, rowHeight / 2f * 0.92f)
        canvas.restoreToCount(save)

        if (expand > 0.6f) {
            val alpha = ((expand - 0.6f) / 0.4f * 255).toInt().coerceIn(0, 255)
            titlePaint.alpha = alpha
            hintPaint.alpha = (alpha * 0.78f).toInt()
            val maxText = cardWidth - dp(40f)
            val titleY = rowHeight + dp(24f)
            canvas.drawText(ellipsize(title, titlePaint, maxText), w / 2f, titleY, titlePaint)
            hint?.let { canvas.drawText(ellipsize(it, hintPaint, maxText), w / 2f, titleY + dp(24f), hintPaint) }
        }
        if (!still) postInvalidateOnAnimation()
    }

    private fun ellipsize(text: String, paint: TextPaint, width: Float) =
        TextUtils.ellipsize(text, paint, width, TextUtils.TruncateAt.END).toString()

    private fun step() {
        val now = System.nanoTime()
        val dt = if (lastFrame == 0L) 0f else ((now - lastFrame) / 1e9f).coerceIn(0f, 0.1f)
        lastFrame = now
        time += dt * phaseSpeed()
        amplitude += (target() - amplitude) * (1 - exp(-dt * 9f))
        // Starts as a pill around the camera, then grows into the card.
        expand += (1f - expand) * (1 - exp(-dt * 6f))
    }

    private fun drawWave(canvas: Canvas, left: Float, right: Float, mid: Float, maxHeight: Float) {
        val width = right - left
        val amp = amplitude * modulation()
        for (i in colors.indices) {
            val breathe = 0.55f + 0.45f * sin(time * 0.45f * (i + 1) + offset[i])
            val height = amp * scale[i] * breathe * maxHeight
            if (height < 0.5f) continue
            val phase = time * speed[i] + offset[i]
            val steps = max(24, (width / 4).toInt())
            val ys = FloatArray(steps + 1) { j ->
                val x = j.toFloat() / steps * 4f - 2f
                val taper = (4.0 / (4.0 + x.toDouble().pow(4))).pow(2).toFloat()
                taper * height * sin(frequency[i] * x * Math.PI.toFloat() - phase)
            }
            path.reset()
            path.moveTo(left, mid)
            for (j in 0..steps) path.lineTo(left + width * j / steps, mid - ys[j])
            for (j in steps downTo 0) path.lineTo(left + width * j / steps, mid + ys[j])
            path.close()
            glow.color = colors[i]
            glow.alpha = 128
            canvas.drawPath(path, glow)
            fill.color = colors[i]
            fill.alpha = 158
            canvas.drawPath(path, fill)
        }
        // Thin resting line, fading as the wave grows.
        val lineAlpha = ((0.55f - amp * 0.4f).coerceIn(0.12f, 0.55f) * 255).toInt()
        fill.color = Color.WHITE
        fill.alpha = lineAlpha
        canvas.drawRect(left + width * 0.04f, mid - dp(0.6f), right - width * 0.04f, mid + dp(0.6f), fill)
    }
}
