package com.example.child_assist.wakeword

import android.content.Context
import android.content.SharedPreferences
import android.os.SystemClock
import io.flutter.plugin.common.EventChannel

/**
 * What the wake-word service and the Flutter side share inside the app process. Main thread only.
 *
 * Persisted (plain preferences, no credentials, no audio): whether the user switched the wake word
 * on, which account did, and the internal tuning, so Android can restart the service after it was
 * stopped for memory. Nothing else about the microphone is stored.
 */
object WakeWordBridge {
    private const val PREFS = "child_assist_wake_word"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_OWNER = "owner"
    private const val KEY_THRESHOLD = "threshold"
    private const val KEY_BOOST = "boost"

    /** How long a detection waits for the app to open and take it. */
    private const val ACTIVATION_TTL_MS = 30_000L

    /** Receives status and detection events while the Flutter UI is running. */
    var events: EventChannel.EventSink? = null

    /** The running service, if any. */
    var service: WakeWordService? = null

    /** MainActivity is on screen (resumed). */
    var activityVisible = false

    /** Why the service is not listening when it should be, e.g. "permission"; null if fine. */
    var issue: String? = null

    /** When the last wake phrase was heard that the app has not taken yet. */
    private var pendingActivationAt: Long? = null

    fun prefs(context: Context): SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isEnabled(context: Context) = prefs(context).getBoolean(KEY_ENABLED, false)

    fun owner(context: Context): String? = prefs(context).getString(KEY_OWNER, null)

    fun tuning(context: Context): WakeWordTuning = prefs(context).let {
        WakeWordTuning.from(mapOf("threshold" to it.getFloat(KEY_THRESHOLD, WakeWordTuning().threshold), "boost" to it.getFloat(KEY_BOOST, WakeWordTuning().boost)))
    }

    fun saveEnabled(context: Context, owner: String, tuning: WakeWordTuning) {
        prefs(context).edit()
            .putBoolean(KEY_ENABLED, true)
            .putString(KEY_OWNER, owner)
            .putFloat(KEY_THRESHOLD, tuning.threshold)
            .putFloat(KEY_BOOST, tuning.boost)
            .apply()
    }

    /** Forgets the switch and the account (turned off, logged out, permission removed). */
    fun clear(context: Context) {
        prefs(context).edit().clear().apply()
        pendingActivationAt = null
    }

    fun markActivation() {
        pendingActivationAt = SystemClock.elapsedRealtime()
    }

    /** True once per detection, if it is recent enough to still act on. */
    fun takeActivation(): Boolean {
        val at = pendingActivationAt ?: return false
        pendingActivationAt = null
        return SystemClock.elapsedRealtime() - at < ACTIVATION_TTL_MS
    }

    fun status(context: Context): Map<String, Any?> {
        val running = service
        return mapOf(
            "type" to "status",
            "enabled" to isEnabled(context),
            "owner" to owner(context),
            "running" to (running != null),
            "listening" to (running?.isListening == true),
            "silenced" to (running?.isSilenced == true),
            "suspendedBy" to (running?.suspendedBy ?: emptyList<String>()),
            "issue" to issue,
        )
    }

    fun emitStatus(context: Context) {
        events?.success(status(context))
    }

    fun emitDetected(keyword: String) {
        events?.success(mapOf("type" to "detected", "keyword" to keyword))
    }
}
