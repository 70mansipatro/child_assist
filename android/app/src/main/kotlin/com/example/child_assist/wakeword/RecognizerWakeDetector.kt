package com.example.child_assist.wakeword

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

/** One way of listening for the wake phrase. Exactly one is used at a time, by [WakeWordService]. */
interface WakeEngine {
    fun start()

    /** Stops listening and closes the microphone. */
    fun stop()

    /** Stops and frees everything. */
    fun release()

    val isRunning: Boolean

    /** The microphone is open and audio is being checked for the phrase. */
    val isRecording: Boolean

    /** The audio session of the current recording, if the engine records itself; 0 otherwise. */
    val audioSessionId: Int
}

/**
 * Listens for "Hey Child" / "Hi Child" with the phone's on-device speech recogniser (Android 12+,
 * e.g. Google's offline model). Used instead of the keyword spotter where available: on the test
 * phone the keyword spotter almost never accepted a real Indian English voice, while the phone's
 * recogniser understood the same voice every time.
 *
 * Only the on-device recogniser is ever used, so no audio leaves the phone before the wake phrase.
 * What it hears is checked for the phrase in memory and dropped; nothing is stored or logged. Each
 * utterance ends after a short silence and listening starts again at once.
 *
 * If the phrase was followed by the question in the same breath ("Hi Child, what is my name?"),
 * the question is passed on with the detection so it is not lost.
 *
 * Main thread only (SpeechRecognizer's requirement).
 */
class RecognizerWakeDetector(
    private val context: Context,
    /** The phrase heard ("HEY_CHILD" / "HI_CHILD") and what followed it in the same utterance. */
    private val onDetected: (String, String) -> Unit,
    private val onFailure: (WakeWordDetector.Failure) -> Unit,
    private val onRecording: (Boolean) -> Unit = {},
) : WakeEngine {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var active = false
    private var listening = false
    private var failures = 0

    /** The last partial result that contained the phrase, in case the utterance ends in an error. */
    private var pendingMatch: Match? = null

    override val isRunning: Boolean get() = active
    override val isRecording: Boolean get() = active && listening
    override val audioSessionId: Int get() = 0

    override fun start() {
        if (active) return
        active = true
        failures = 0
        WakeLog.d("wake engine: on-device speech recogniser")
        listen()
    }

    override fun stop() {
        active = false
        main.removeCallbacks(restart)
        pendingMatch = null
        recognizer?.let {
            try {
                it.cancel()
                it.destroy()
            } catch (e: RuntimeException) {
                // Already gone.
            }
        }
        recognizer = null
        setListening(false)
        WakeLog.d("microphone released")
    }

    override fun release() = stop()

    private val restart = Runnable { if (active) listen() }

    private fun scheduleRestart(delayMs: Long) {
        main.removeCallbacks(restart)
        main.postDelayed(restart, delayMs)
    }

    private fun listen() {
        if (!active) return
        pendingMatch = null
        val current = recognizer ?: try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also {
                it.setRecognitionListener(listener)
                recognizer = it
            }
        } catch (e: RuntimeException) {
            WakeLog.w("on-device recogniser unavailable: ${e.javaClass.simpleName}")
            active = false
            onFailure(WakeWordDetector.Failure.ENGINE)
            return
        }
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
        }
        try {
            current.startListening(intent)
        } catch (e: RuntimeException) {
            WakeLog.w("recogniser start failed: ${e.javaClass.simpleName}")
            recover()
        }
    }

    /** Something went wrong with this recogniser: a fresh one shortly, backing off if it repeats. */
    private fun recover() {
        recognizer?.let {
            try {
                it.destroy()
            } catch (e: RuntimeException) {
                // Already gone.
            }
        }
        recognizer = null
        setListening(false)
        failures++
        if (failures > MAX_FAILURES) {
            active = false
            onFailure(WakeWordDetector.Failure.MICROPHONE)
            return
        }
        scheduleRestart(minOf(500L * failures, 5000L))
    }

    private fun setListening(value: Boolean) {
        if (listening == value) return
        listening = value
        onRecording(value)
    }

    private fun heard(texts: List<String>?): Match? = texts?.firstNotNullOfOrNull { match(it) }

    private fun detect(found: Match) {
        WakeLog.d("wake phrase recognised: ${found.keyword} (question with it: ${found.question.isNotEmpty()})")
        onDetected(found.keyword, found.question)
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {
            failures = 0
            if (!listening) WakeLog.d("listening")
            setListening(true)
        }

        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            if (!active) return
            heard(partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION))?.let { pendingMatch = it }
        }

        override fun onResults(results: Bundle?) {
            if (!active) return
            // The whole utterance: the phrase and anything said right after it.
            val texts = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            val found = heard(texts) ?: pendingMatch
            pendingMatch = null
            if (found != null) return detect(found)
            // Counts only, never the words: shows whether speech is being understood at all.
            val words = texts?.firstOrNull()?.split(' ')?.count { it.isNotBlank() } ?: 0
            if (words > 0) WakeLog.d("utterance without the wake phrase ($words words)")
            scheduleRestart(RESTART_MS)
        }

        override fun onError(error: Int) {
            if (!active) return
            val found = pendingMatch
            pendingMatch = null
            if (found != null) return detect(found)
            when (error) {
                // Silence or nothing understood: the normal end of a quiet stretch.
                SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> scheduleRestart(RESTART_MS)
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> {
                    active = false
                    onFailure(WakeWordDetector.Failure.PERMISSION)
                }
                ERROR_LANGUAGE_NOT_SUPPORTED, ERROR_LANGUAGE_UNAVAILABLE -> {
                    WakeLog.w("on-device recogniser has no language model ($error)")
                    active = false
                    onFailure(WakeWordDetector.Failure.ENGINE)
                }
                else -> {
                    WakeLog.w("recogniser error $error")
                    recover()
                }
            }
        }
    }

    data class Match(val keyword: String, val question: String)

    companion object {
        private const val RESTART_MS = 80L
        private const val MAX_FAILURES = 20
        private const val ERROR_LANGUAGE_NOT_SUPPORTED = 12
        private const val ERROR_LANGUAGE_UNAVAILABLE = 13

        // "Hey Child" / "Hi Child" as recognisers write them, including common Indian English
        // spellings ("hai child", "hey chaild") and Hindi script.
        private val HEY = setOf("hey", "hay", "he", "hei", "हे", "हेय")
        private val WAKE = Regex(
            """(?<![\p{L}])(hey|hay|hei|he|hi|hii|hai|high|hy|हे|हेय|हाय|है)[\s,.!-]*(child|chiled|chyld|chaild|childe|चाइल्ड|चाईल्ड)(?![\p{L}])""",
            RegexOption.IGNORE_CASE,
        )

        /** True on Android 12+ phones with an on-device recogniser. */
        fun isAvailable(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

        /** The wake phrase in [text], and what was said after it; null if it is not there. */
        fun match(text: String): Match? {
            val found = WAKE.find(text) ?: return null
            val greeting = found.groupValues[1].lowercase()
            val keyword = if (greeting in HEY) "HEY_CHILD" else "HI_CHILD"
            val question = text.substring(found.range.last + 1).trim(' ', ',', '.', '!', '?', ':', ';', '-')
            return Match(keyword, question)
        }
    }
}
