package com.example.child_assist.wakeword

import android.Manifest
import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.example.child_assist.MainActivity
import com.example.child_assist.R

/**
 * "Hey Child": listens for the wake phrase on the device while the user has switched it on.
 *
 * A foreground service of type microphone, so Android shows a persistent notification the whole
 * time it runs and the microphone indicator while it records. It never runs unless the user
 * switched the wake word on, and stops when they switch it off (in the app or from the
 * notification), log out, or the microphone permission is removed.
 *
 * The microphone is only open while listening for the phrase. It is closed (so the phone's speech
 * recogniser can hear the question) while the user is asking something, while Child Assist reads a
 * reply aloud (so it cannot wake itself), during tap-to-talk and during calls. Each reason is
 * tracked separately; listening resumes when none is left.
 *
 * No wake lock: while recording, Android's audio system keeps the CPU running on its own.
 */
class WakeWordService : Service() {
    private val main = Handler(Looper.getMainLooper())
    private lateinit var audioManager: AudioManager
    private var detector: WakeWordDetector? = null
    private var tuning = WakeWordTuning()
    private val suspensions = linkedSetOf<String>()
    private var lastDetection = 0L
    private var failures = 0
    private var silenced = false
    private var inForeground = false

    val suspendedBy: List<String> get() = suspensions.toList()
    val isListening: Boolean get() = detector?.isRunning == true && !silenced
    val isSilenced: Boolean get() = silenced

    // ---------------------------------------------------------------------------------------------
    // Lifecycle

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        createChannels(this)
        WakeWordBridge.service = this
        watchCalls()
        watchRecording()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_TURN_OFF) {
            // "Turn off" in the notification: the same as switching it off in the app.
            log("turned off from the notification")
            WakeWordBridge.clear(this)
            WakeWordBridge.issue = null
            shutDown()
            return START_NOT_STICKY
        }
        // A null intent: Android restarted the service after stopping it (START_STICKY).
        if (!WakeWordBridge.isEnabled(this)) {
            shutDown()
            return START_NOT_STICKY
        }
        if (!enterForeground()) return START_NOT_STICKY
        if (!hasMicrophonePermission()) {
            log("microphone permission missing; stopping")
            WakeWordBridge.clear(this)
            WakeWordBridge.issue = ISSUE_PERMISSION
            shutDown()
            return START_NOT_STICKY
        }
        val wanted = WakeWordBridge.tuning(this)
        if (wanted != tuning) {
            detector?.release()
            detector = null
            tuning = wanted
        }
        WakeWordBridge.issue = null
        failures = 0
        log(if (intent == null) "restarted by Android" else "started")
        apply()
        return START_STICKY
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        detector?.release()
        detector = null
        stopWatching()
        if (WakeWordBridge.service === this) WakeWordBridge.service = null
        WakeWordBridge.emitStatus(this)
        super.onDestroy()
    }

    private fun enterForeground(): Boolean {
        return try {
            ServiceCompat.startForeground(
                this,
                NOTIFICATION_ID,
                buildNotification(),
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0,
            )
            inForeground = true
            true
        } catch (e: Exception) {
            // Android 11+ does not let a microphone service start while the app is in the
            // background (e.g. Android restarting it after the app was closed). It starts again
            // the next time the app is opened. Never pretend it is listening.
            Log.w(TAG, "could not start in the foreground: ${e.javaClass.simpleName}")
            WakeWordBridge.issue = ISSUE_START_BLOCKED
            shutDown()
            false
        }
    }

    /** Stops listening and the service. What the user switched on is kept unless cleared first. */
    fun shutDown() {
        main.removeCallbacksAndMessages(null)
        detector?.release()
        detector = null
        suspensions.clear()
        if (inForeground) ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        inForeground = false
        stopSelf()
        WakeWordBridge.emitStatus(this)
    }

    // ---------------------------------------------------------------------------------------------
    // Pausing and resuming

    /** Closes the microphone for [reason] until [resume] is called with it. */
    fun suspend(reason: String) {
        if (reason == REASON_INTERACTION) {
            // Never stuck: if the app does not finish the question, listening comes back.
            main.removeCallbacks(interactionWatchdog)
            main.postDelayed(interactionWatchdog, INTERACTION_TIMEOUT_MS)
        }
        if (suspensions.add(reason)) apply()
    }

    fun resume(reason: String) {
        if (reason == REASON_INTERACTION) main.removeCallbacks(interactionWatchdog)
        if (suspensions.remove(reason)) {
            // Freshly allowed again: retry a microphone that failed earlier.
            failures = 0
            apply()
        }
    }

    private val interactionWatchdog = Runnable {
        log("question not finished in time; listening for the wake phrase again")
        resume(REASON_INTERACTION)
    }

    /** Opens or closes the microphone to match the current reasons, and updates the notification. */
    private fun apply() {
        if (suspensions.isEmpty()) {
            val current = detector ?: WakeWordDetector(this, tuning, ::onDetected, ::onFailure).also { detector = it }
            current.start()
        } else {
            detector?.stop()
        }
        silenced = false
        refresh()
    }

    private fun refresh() {
        if (inForeground) NotificationManagerCompat.from(this).notifySafely(NOTIFICATION_ID, buildNotification())
        WakeWordBridge.emitStatus(this)
    }

    // ---------------------------------------------------------------------------------------------
    // Detection

    private fun onDetected(keyword: String) {
        main.post { handleDetected(keyword) }
    }

    private fun handleDetected(keyword: String) {
        val now = SystemClock.elapsedRealtime()
        // One phrase can be reported twice in a row; and audio still in flight right after a
        // pause began must not start a second question.
        if (now - lastDetection < DEBOUNCE_MS || suspensions.isNotEmpty() || detector?.isRunning != true) return
        lastDetection = now
        failures = 0
        log("wake phrase heard")
        // Free the microphone at once so the question can be heard.
        suspend(REASON_INTERACTION)
        if (WakeWordBridge.events != null) WakeWordBridge.emitDetected(keyword) else WakeWordBridge.markActivation()
        if (!WakeWordBridge.activityVisible) openApp()
    }

    /**
     * Brings Child Assist to the screen for the question. Android 10+ does not let a background
     * service open an activity, so a full-screen notification does it: with the screen off or
     * locked it opens the app directly; while the phone is in use it appears as a heads-up
     * notification the user taps.
     */
    private fun openApp() {
        val intent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_ACTIVATE
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        if (WakeWordBridge.events == null) WakeWordBridge.markActivation()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            startActivity(intent)
            return
        }
        val open = PendingIntent.getActivity(this, 1, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(this, ACTIVATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_child_assist)
            .setColor(ContextCompat.getColor(this, R.color.notification_color))
            .setContentTitle("Child Assist is listening")
            .setContentText("Ask your question.")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setFullScreenIntent(open, true)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setTimeoutAfter(INTERACTION_TIMEOUT_MS)
            .build()
        NotificationManagerCompat.from(this).notifySafely(ACTIVATION_NOTIFICATION_ID, notification)
    }

    private fun onFailure(failure: WakeWordDetector.Failure) {
        main.post { handleFailure(failure) }
    }

    private fun handleFailure(failure: WakeWordDetector.Failure) {
        when (failure) {
            WakeWordDetector.Failure.PERMISSION -> {
                WakeWordBridge.clear(this)
                WakeWordBridge.issue = ISSUE_PERMISSION
                shutDown()
            }
            WakeWordDetector.Failure.ENGINE -> {
                WakeWordBridge.issue = ISSUE_ENGINE
                shutDown()
            }
            WakeWordDetector.Failure.MICROPHONE -> {
                if (!hasMicrophonePermission()) {
                    WakeWordBridge.clear(this)
                    WakeWordBridge.issue = ISSUE_PERMISSION
                    shutDown()
                    return
                }
                failures++
                if (failures > MAX_RETRIES) {
                    // Fail safely: the microphone is released and the user is told.
                    WakeWordBridge.issue = ISSUE_MICROPHONE
                    shutDown()
                    return
                }
                detector?.stop()
                refresh()
                // E.g. a headset was plugged in or another app briefly held the microphone.
                main.postDelayed({ if (suspensions.isEmpty()) apply() }, 1000L shl failures)
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Calls and other apps using the microphone

    private var modeListener: Any? = null
    private val pollCall = object : Runnable {
        override fun run() {
            onAudioMode()
            main.postDelayed(this, CALL_POLL_MS)
        }
    }

    private fun watchCalls() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = AudioManager.OnModeChangedListener { onAudioMode() }
            audioManager.addOnModeChangedListener(ContextCompat.getMainExecutor(this), listener)
            modeListener = listener
        } else {
            main.postDelayed(pollCall, CALL_POLL_MS)
        }
        onAudioMode()
    }

    private fun onAudioMode() {
        if (WakeWordDetector.inCall(audioManager)) suspend(REASON_CALL) else resume(REASON_CALL)
    }

    private var recordingCallback: AudioManager.AudioRecordingCallback? = null

    /** Android 10+: notices when another app or a call takes the microphone (our audio goes silent). */
    private fun watchRecording() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val callback = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                val session = detector?.audioSessionId ?: 0
                val ours = configs.firstOrNull { it.clientAudioSessionId == session && session != 0 }
                val nowSilenced = ours?.isClientSilenced == true
                if (nowSilenced != silenced) {
                    silenced = nowSilenced
                    log(if (silenced) "microphone taken by another app" else "microphone back")
                    refresh()
                }
            }
        }
        audioManager.registerAudioRecordingCallback(callback, main)
        recordingCallback = callback
    }

    private fun stopWatching() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (modeListener as? AudioManager.OnModeChangedListener)?.let { audioManager.removeOnModeChangedListener(it) }
        }
        modeListener = null
        recordingCallback?.let { audioManager.unregisterAudioRecordingCallback(it) }
        recordingCallback = null
    }

    // ---------------------------------------------------------------------------------------------
    // Notification

    private fun buildNotification(): Notification {
        val text = when {
            REASON_CALL in suspensions -> "Paused during the call."
            silenced -> "Paused while another app uses the microphone."
            REASON_INTERACTION in suspensions -> "Listening to your question."
            REASON_SPEAKING in suspensions -> "Child Assist is answering."
            suspensions.isNotEmpty() -> "Paused while you talk to Child Assist."
            else -> "Say “Hey Child”. Listening happens on this phone; nothing is recorded or sent."
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val turnOff = PendingIntent.getService(
            this,
            2,
            Intent(this, WakeWordService::class.java).setAction(ACTION_TURN_OFF),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_child_assist)
            .setColor(ContextCompat.getColor(this, R.color.notification_color))
            .setContentTitle("Child Assist voice activation is on")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(open)
            .addAction(0, "Turn off", turnOff)
            .build()
    }

    private fun hasMicrophonePermission() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "WakeWord"
        const val ACTION_TURN_OFF = "com.example.child_assist.wakeword.TURN_OFF"
        const val ACTION_ACTIVATE = "com.example.child_assist.wakeword.ACTIVATE"
        private const val CHANNEL_ID = "child_assist_voice_activation"
        private const val ACTIVATION_CHANNEL_ID = "child_assist_voice_activation_alert"
        private const val NOTIFICATION_ID = 7301
        const val ACTIVATION_NOTIFICATION_ID = 7302

        const val REASON_INTERACTION = "interaction"
        const val REASON_SPEAKING = "speaking"
        const val REASON_CALL = "call"

        const val ISSUE_PERMISSION = "permission"
        const val ISSUE_START_BLOCKED = "startBlocked"
        const val ISSUE_ENGINE = "engine"
        const val ISSUE_MICROPHONE = "microphone"

        private const val DEBOUNCE_MS = 2500L
        private const val INTERACTION_TIMEOUT_MS = 90_000L
        private const val CALL_POLL_MS = 3000L
        private const val MAX_RETRIES = 3

        /** Starts (or re-applies) listening. Call only while the app is in the foreground. */
        fun start(context: Context) {
            ContextCompat.startForegroundService(context, Intent(context, WakeWordService::class.java))
        }

        fun createChannels(context: Context) {
            val manager = NotificationManagerCompat.from(context)
            manager.createNotificationChannel(
                NotificationChannelCompat.Builder(CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_LOW)
                    .setName("Voice activation")
                    .setDescription("Shown while Child Assist listens for “Hey Child”.")
                    .setShowBadge(false)
                    .build(),
            )
            manager.createNotificationChannel(
                NotificationChannelCompat.Builder(ACTIVATION_CHANNEL_ID, NotificationManagerCompat.IMPORTANCE_HIGH)
                    .setName("Voice activation alerts")
                    .setDescription("Opens Child Assist after you say “Hey Child”.")
                    .setSound(null, null)
                    .setVibrationEnabled(false)
                    .setShowBadge(false)
                    .build(),
            )
        }

        private fun log(message: String) {
            Log.i(TAG, message)
        }
    }
}

/** Without the notification permission (Android 13+) Android hides it; the service still runs. */
private fun NotificationManagerCompat.notifySafely(id: Int, notification: Notification) {
    try {
        notify(id, notification)
    } catch (e: SecurityException) {
        // POST_NOTIFICATIONS not granted.
    }
}
