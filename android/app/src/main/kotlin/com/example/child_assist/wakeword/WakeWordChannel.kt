package com.example.child_assist.wakeword

import android.Manifest
import android.app.Activity
import android.app.KeyguardManager
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.WindowManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * The wake word's channel to Flutter ("child_assist/wake_word"), plus what MainActivity does when
 * the wake phrase opens it. Flutter owns the decisions (who is signed in, whether the user switched
 * it on, the permission flow); this side runs the service and reports what Android says.
 */
class WakeWordChannel(private val activity: Activity) {
    private val context: Context get() = activity.applicationContext

    /** This screen was closed; the engine (and these handlers) may outlive it until a new one opens. */
    private var destroyed = false

    fun register(engine: FlutterEngine) {
        // Before the service exists too, so a deferred or refused start shows in the diagnostics.
        WakeLog.init(context)
        MethodChannel(engine.dartExecutor.binaryMessenger, "child_assist/wake_word").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> result.success(start(call.argument<String>("owner"), call.argument<Map<*, *>>("tuning")))
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "suspend" -> {
                    call.argument<String>("reason")?.let { WakeWordBridge.service?.suspend(it) }
                    result.success(null)
                }
                "resume" -> {
                    call.argument<String>("reason")?.let { WakeWordBridge.service?.resume(it) }
                    result.success(null)
                }
                "playCue" -> {
                    WakeWordService.playCue()
                    result.success(null)
                }
                "status" -> result.success(WakeWordBridge.status(context))
                "takeActivation" -> result.success(WakeWordBridge.takeActivation())
                "lockState" -> result.success(lockState())
                "showOverLockScreen" -> {
                    showOverLockScreen(call.argument<Boolean>("show") == true)
                    result.success(null)
                }
                "keepScreenOn" -> {
                    if (destroyed) {
                        // No window to keep on.
                    } else if (call.argument<Boolean>("on") == true) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "requestUnlock" -> requestUnlock(result)
                "canUseFullScreenIntent" -> result.success(canUseFullScreenIntent())
                "openFullScreenIntentSettings" -> result.success(openFullScreenIntentSettings())
                // Optional: lets the wake word open Child Assist while another app is in use.
                "canOpenFromBackground" -> result.success(
                    Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || Settings.canDrawOverlays(context),
                )
                "openBackgroundOpenSettings" -> result.success(openSettings(Settings.ACTION_MANAGE_OVERLAY_PERMISSION))
                // The waveform above other apps and the Home screen while a question is in progress.
                "showOverlay" -> result.success(
                    WakeOverlay.show(
                        context,
                        call.argument<String>("phase") ?: "listening",
                        call.argument<String>("title") ?: "",
                        call.argument<String>("hint"),
                    ),
                )
                "hideOverlay" -> {
                    WakeOverlay.hide()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(engine.dartExecutor.binaryMessenger, "child_assist/wake_word/events").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    WakeWordBridge.events = events
                    WakeWordBridge.emitStatus(context)
                }

                override fun onCancel(arguments: Any?) {
                    WakeWordBridge.events = null
                }
            },
        )
    }

    /** "started", "permission" (RECORD_AUDIO not granted) or "startBlocked" (Android refused). */
    private fun start(owner: String?, tuning: Map<*, *>?): String {
        if (owner.isNullOrEmpty()) return "invalid"
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return WakeWordService.ISSUE_PERMISSION
        }
        WakeWordBridge.saveEnabled(context, owner, WakeWordTuning.from(tuning))
        WakeWordBridge.issue = null
        if (!WakeWordBridge.activityVisible) {
            // Android 14 only gives a foreground service the microphone if it is started while the
            // app is on screen. Started a moment too early or too late (e.g. while the app is
            // opening, or just after the user left it), Android starts it but refuses the
            // microphone. Not started now; [onVisible] starts it as soon as the app is on screen.
            WakeLog.d("start deferred until Child Assist is on screen")
            WakeWordBridge.issue = WakeWordService.ISSUE_START_BLOCKED
            WakeWordBridge.emitStatus(context)
            return WakeWordService.ISSUE_START_BLOCKED
        }
        return startService()
    }

    private fun startService(): String = try {
        WakeWordService.start(context)
        "started"
    } catch (e: IllegalStateException) {
        // ForegroundServiceStartNotAllowedException (Android 12+) when not in the foreground.
        WakeLog.w("start refused: ${e.javaClass.simpleName}")
        WakeWordBridge.issue = WakeWordService.ISSUE_START_BLOCKED
        WakeWordService.ISSUE_START_BLOCKED
    } catch (e: SecurityException) {
        WakeLog.w("start refused: ${e.javaClass.simpleName}")
        WakeWordBridge.issue = WakeWordService.ISSUE_START_BLOCKED
        WakeWordService.ISSUE_START_BLOCKED
    }

    private fun stop() {
        WakeOverlay.hide()
        WakeWordBridge.clear(context)
        WakeWordBridge.issue = null
        WakeWordBridge.service?.shutDown()
        NotificationManagerCompat.from(context).cancel(WakeWordService.ACTIVATION_NOTIFICATION_ID)
        WakeWordBridge.emitStatus(context)
    }

    private fun keyguard() = context.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    private fun lockState(): Map<String, Boolean> {
        val keyguard = keyguard()
        return mapOf("locked" to keyguard.isKeyguardLocked, "secure" to keyguard.isKeyguardSecure)
    }

    /**
     * While the user asks a question with the phone locked, Child Assist shows above the lock
     * screen and turns the screen on. Switched off again as soon as the question is done, so the
     * lock screen comes back.
     */
    fun showOverLockScreen(show: Boolean) {
        if (destroyed) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            activity.setShowWhenLocked(show)
            activity.setTurnScreenOn(show)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (show) activity.window.addFlags(flags) else activity.window.clearFlags(flags)
        }
    }

    /** Asks Android to unlock (PIN, pattern or fingerprint). True once unlocked. */
    private fun requestUnlock(result: MethodChannel.Result) {
        val keyguard = keyguard()
        if (!keyguard.isKeyguardLocked) return result.success(true)
        if (destroyed) return result.success(false)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return result.success(false)
        keyguard.requestDismissKeyguard(activity, object : KeyguardManager.KeyguardDismissCallback() {
            override fun onDismissSucceeded() = result.success(true)
            override fun onDismissCancelled() = result.success(false)
            override fun onDismissError() = result.success(false)
        })
    }

    /** Android 14+ can withhold full-screen notifications, which open the app from a locked phone. */
    private fun canUseFullScreenIntent(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return true
        return (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).canUseFullScreenIntent()
    }

    private fun openFullScreenIntentSettings(): Boolean {
        if (Build.VERSION.SDK_INT < 34) return false
        return openSettings(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
    }

    /** This app's page for one special permission in the phone's Settings. */
    private fun openSettings(action: String): Boolean = try {
        activity.startActivity(Intent(action, Uri.parse("package:${context.packageName}")))
        true
    } catch (e: ActivityNotFoundException) {
        false
    }

    /** MainActivity was opened by the wake phrase (see [WakeWordService.openApp]). */
    fun onActivationIntent(intent: Intent?) {
        if (intent?.action != WakeWordService.ACTION_ACTIVATE) return
        NotificationManagerCompat.from(context).cancel(WakeWordService.ACTIVATION_NOTIFICATION_ID)
        // Shown at once (the screen may be off); Flutter switches it off again after the question,
        // or asks to unlock first if the user does not allow answers on the lock screen.
        if (keyguard().isKeyguardLocked) showOverLockScreen(true)
        // Read once: a later recreation of the activity must not start another question.
        intent.action = Intent.ACTION_MAIN
    }

    fun onVisible(visible: Boolean) {
        WakeWordBridge.activityVisible = visible
        // Switched on, but Android refused (or the app deferred) the start because Child Assist was
        // not on screen at that moment: now it is, so the microphone may be used. Only for the
        // account that switched it on (logout and switching account clear it first).
        if (visible &&
            WakeWordBridge.service == null &&
            WakeWordBridge.issue == WakeWordService.ISSUE_START_BLOCKED &&
            WakeWordBridge.isEnabled(context) &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        ) {
            WakeLog.d("Child Assist on screen: starting the deferred wake word")
            WakeWordBridge.issue = null
            startService()
        }
    }

    /**
     * The screen is gone, but the Flutter engine is kept (see MainActivity), so the event channel
     * stays connected: a wake phrase heard now still reaches the app.
     */
    fun onDestroy() {
        destroyed = true
        WakeWordBridge.activityVisible = false
    }
}
