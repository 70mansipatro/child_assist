package com.example.child_assist.wakeword

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
import android.util.Log
import com.k2fsa.sherpa.onnx.FeatureConfig
import com.k2fsa.sherpa.onnx.KeywordSpotter
import com.k2fsa.sherpa.onnx.KeywordSpotterConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineStream
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import kotlin.math.max
import kotlin.math.sqrt

/**
 * How eagerly "Hey Child" / "Hi Child" is accepted. Internal only: never shown to users.
 *
 * Measured offline with this exact model on synthesized speech (two voices, three speaking rates,
 * room noise): threshold 0.20 detected 29/30 wake phrases with 0 false activations on 78 clips of
 * similar phrases ("Hey Charles", "Hi Chad", "Hey kid", "my child is at school"...). 0.15 was
 * slightly more eager, 0.25 missed more. "High child ..." sounds the same as "Hi Child" and does
 * trigger; no acoustic model can tell those apart.
 */
data class WakeWordTuning(
    /** Per-token probability the whole phrase must reach (sherpa-onnx `keywords_threshold`). */
    val threshold: Float = 0.20f,
    /** Context boost for the phrase tokens (sherpa-onnx `keywords_score`). */
    val boost: Float = 1.0f,
) {
    companion object {
        fun from(map: Map<*, *>?): WakeWordTuning {
            val defaults = WakeWordTuning()
            val threshold = (map?.get("threshold") as? Number)?.toFloat() ?: defaults.threshold
            val boost = (map?.get("boost") as? Number)?.toFloat() ?: defaults.boost
            // Clamped, so a bad value can neither trigger on everything nor never trigger.
            return WakeWordTuning(threshold.coerceIn(0.10f, 0.40f), boost.coerceIn(0.5f, 2.0f))
        }
    }
}

/**
 * Listens for the wake phrase on the device. Microphone audio goes into the on-device keyword
 * spotter in memory and is dropped right after; it is never written anywhere or sent anywhere.
 *
 * Battery: a cheap loudness check runs on every 100 ms of audio, and the neural model only runs
 * while there is sound (plus a short tail). In a quiet room the model is idle. The microphone is
 * released completely while [stop]ped.
 *
 * All methods are called from the main thread. Audio is read and decoded on one worker thread.
 */
class WakeWordDetector(
    private val context: Context,
    private val tuning: WakeWordTuning,
    /** Called on the worker thread with the phrase heard, e.g. "HEY_CHILD". */
    private val onDetected: (String) -> Unit,
    /** Called on the worker thread when listening cannot continue. */
    private val onFailure: (Failure) -> Unit,
) {
    enum class Failure {
        /** The model could not be loaded. */
        ENGINE,

        /** The microphone could not be opened or stopped delivering audio. */
        MICROPHONE,

        /** RECORD_AUDIO is not granted. */
        PERMISSION,
    }

    @Volatile private var running = false
    private var worker: Thread? = null
    @Volatile private var record: AudioRecord? = null

    // Created on the worker thread the first time, then kept until [release] (loading takes a moment).
    @Volatile private var spotter: KeywordSpotter? = null

    /** The audio session of the current recording, to recognise it in recording callbacks. */
    val audioSessionId: Int get() = record?.audioSessionId ?: 0

    val isRunning: Boolean get() = running

    fun start() {
        if (running) return
        running = true
        worker = Thread({ run() }, "WakeWordDetector").apply { start() }
    }

    /** Stops listening and closes the microphone. Returns once the worker has let go of it. */
    fun stop() {
        if (!running && worker == null) return
        running = false
        // Unblocks a read in progress.
        try {
            record?.stop()
        } catch (e: IllegalStateException) {
            // Not recording.
        }
        worker?.join(STOP_TIMEOUT_MS)
        worker = null
    }

    /** Stops and frees the model. */
    fun release() {
        stop()
        spotter?.release()
        spotter = null
    }

    @SuppressLint("MissingPermission") // Checked by the service before starting.
    private fun run() {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val kws = spotter ?: try {
            load().also { spotter = it }
        } catch (e: Throwable) {
            Log.e(TAG, "wake word model failed to load: ${e.javaClass.simpleName}")
            running = false
            onFailure(Failure.ENGINE)
            return
        }

        val minBuffer = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val audio = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_RECOGNITION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBuffer, CHUNK * 2 * 4),
            )
        } catch (e: SecurityException) {
            running = false
            onFailure(Failure.PERMISSION)
            return
        } catch (e: IllegalArgumentException) {
            running = false
            onFailure(Failure.MICROPHONE)
            return
        }
        if (audio.state != AudioRecord.STATE_INITIALIZED) {
            audio.release()
            running = false
            onFailure(Failure.MICROPHONE)
            return
        }
        record = audio
        val stream = kws.createStream("")
        try {
            audio.startRecording()
            if (audio.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                if (running) onFailure(Failure.MICROPHONE)
                return
            }
            listen(audio, kws, stream)
        } catch (e: IllegalStateException) {
            if (running) onFailure(Failure.MICROPHONE)
        } finally {
            running = false
            try {
                audio.stop()
            } catch (e: IllegalStateException) {
                // Already stopped.
            }
            audio.release()
            record = null
            stream.release()
        }
    }

    private fun listen(audio: AudioRecord, kws: KeywordSpotter, stream: OnlineStream) {
        val pcm = ShortArray(CHUNK)
        val gate = SoundGate()
        while (running) {
            val read = audio.read(pcm, 0, CHUNK)
            if (!running) return
            if (read < 0) {
                // ERROR_DEAD_OBJECT etc.: the microphone went away (e.g. audio routing changed).
                Log.w(TAG, "microphone read failed: $read")
                onFailure(Failure.MICROPHONE)
                return
            }
            if (read == 0) continue
            val samples = FloatArray(read) { pcm[it] / 32768f }
            for (chunk in gate.push(samples)) {
                stream.acceptWaveform(chunk, SAMPLE_RATE)
                while (kws.isReady(stream)) {
                    kws.decode(stream)
                    val keyword = kws.getResult(stream).keyword
                    if (keyword.isNotEmpty()) {
                        kws.reset(stream)
                        onDetected(keyword)
                    }
                }
            }
            // The samples are not kept: each buffer is overwritten by the next read.
        }
    }

    private fun load(): KeywordSpotter {
        val config = KeywordSpotterConfig(
            featConfig = FeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = "$MODEL_DIR/encoder.int8.onnx",
                    decoder = "$MODEL_DIR/decoder.onnx",
                    joiner = "$MODEL_DIR/joiner.int8.onnx",
                ),
                tokens = "$MODEL_DIR/tokens.txt",
                numThreads = 1,
                provider = "cpu",
                modelType = "zipformer2",
            ),
            maxActivePaths = 4,
            keywordsFile = "$MODEL_DIR/keywords.txt",
            keywordsScore = tuning.boost,
            keywordsThreshold = tuning.threshold,
            numTrailingBlanks = 1,
        )
        return KeywordSpotter(context.assets, config)
    }

    /**
     * Passes audio on only while there is sound: a 100 ms chunk louder than both an absolute floor
     * and 3x the tracked background level opens the gate, which stays open for 1.5 s after the last
     * loud chunk. The 300 ms before it opened are passed on too, so the start of "Hey" is kept.
     * Validated offline against the same model: detection unchanged in quiet and normal rooms.
     */
    private class SoundGate {
        private var noiseFloor = -1.0
        private val preRoll = ArrayDeque<FloatArray>()
        private var hangover = 0

        fun push(chunk: FloatArray): List<FloatArray> {
            var sum = 0.0
            for (s in chunk) sum += s * s
            val rms = sqrt(sum / chunk.size) + 1e-9
            noiseFloor = when {
                noiseFloor < 0 -> rms
                rms < noiseFloor -> 0.5 * noiseFloor + 0.5 * rms
                else -> 0.995 * noiseFloor + 0.005 * rms
            }
            val out = ArrayList<FloatArray>(PRE_ROLL_CHUNKS + 1)
            if (rms > max(MIN_RMS, noiseFloor * NOISE_RATIO)) {
                if (hangover == 0) out.addAll(preRoll)
                preRoll.clear()
                hangover = HANGOVER_CHUNKS
            }
            if (hangover > 0) {
                out.add(chunk)
                hangover--
            } else {
                preRoll.addLast(chunk)
                if (preRoll.size > PRE_ROLL_CHUNKS) preRoll.removeFirst()
            }
            return out
        }
    }

    companion object {
        private const val TAG = "WakeWord"
        const val SAMPLE_RATE = 16000
        private const val CHUNK = SAMPLE_RATE / 10
        private const val MODEL_DIR = "wake_word"
        private const val STOP_TIMEOUT_MS = 1500L
        private const val MIN_RMS = 0.002
        private const val NOISE_RATIO = 3.0
        private const val PRE_ROLL_CHUNKS = 3
        private const val HANGOVER_CHUNKS = 15

        /** True while a phone or VoIP call is using audio; the wake word pauses for it. */
        fun inCall(audioManager: AudioManager): Boolean = when (audioManager.mode) {
            AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION, AudioManager.MODE_RINGTONE -> true
            else -> false
        }
    }
}
