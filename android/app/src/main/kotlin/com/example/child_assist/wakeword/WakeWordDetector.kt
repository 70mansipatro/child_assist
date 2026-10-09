package com.example.child_assist.wakeword

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Process
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
 * Measured with this exact model, keyword file and sound gate on synthesized speech (two voices,
 * three speaking rates, room noise): threshold 0.20 with 4 trailing blanks detected 32/36 wake
 * phrases and rejected "Hey Google", "Hi Google", "Hey Charles", "Hi Chad", "My child is here",
 * "Where is my child?", "Child Assist", "Hello child" and "Hey children". "High child" sounds the
 * same as "Hi Child" and does trigger; no acoustic model can tell those apart.
 */
data class WakeWordTuning(
    /**
     * Per-token probability the whole phrase must reach (sherpa-onnx `keywords_threshold`).
     * Lowered from 0.20 (and the boost raised) after a real, non-synthesized Indian English voice
     * was accepted only occasionally on the test phone while the synthesized clips always were.
     */
    val threshold: Float = 0.06f,
    /** Context boost for the phrase tokens (sherpa-onnx `keywords_score`). */
    val boost: Float = 2.5f,
    /**
     * Silence frames (40 ms each) required after "child" (sherpa-onnx `num_trailing_blanks`).
     * 4 rejected "Hey children" but also missed a real speaker who paused only briefly; 2 accepts
     * a short pause, at the cost of sometimes accepting "Hey children".
     */
    val trailingBlanks: Int = 2,
) {
    companion object {
        fun from(map: Map<*, *>?): WakeWordTuning {
            val defaults = WakeWordTuning()
            val threshold = (map?.get("threshold") as? Number)?.toFloat() ?: defaults.threshold
            val boost = (map?.get("boost") as? Number)?.toFloat() ?: defaults.boost
            val blanks = (map?.get("trailingBlanks") as? Number)?.toInt() ?: defaults.trailingBlanks
            // Clamped, so a bad value can neither trigger on everything nor never trigger.
            return WakeWordTuning(threshold.coerceIn(0.05f, 0.40f), boost.coerceIn(0.5f, 3.0f), blanks.coerceIn(1, 8))
        }
    }
}

/**
 * The on-device keyword spotter: the model, the wake phrases and a sound gate. Feed it 16 kHz mono
 * float samples; it says which phrase was heard. Nothing is kept: each chunk is decoded and dropped.
 * Not thread-safe; one thread at a time. Also used directly by the instrumented tests.
 */
class WakeWordEngine(context: Context, tuning: WakeWordTuning) {
    private val spotter: KeywordSpotter = KeywordSpotter(
        context.assets,
        KeywordSpotterConfig(
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
            numTrailingBlanks = tuning.trailingBlanks,
        ),
    )
    private var stream: OnlineStream = spotter.createStream("")
    private var gate = SoundGate()

    /** 100 ms chunks the model actually decoded (after the sound gate), for diagnostics. */
    var decodedChunks = 0L
        private set

    /** Feeds audio; returns the phrase heard ("HEY_CHILD" / "HI_CHILD") or null. */
    fun accept(samples: FloatArray): String? {
        var heard: String? = null
        for (chunk in gate.push(samples)) {
            decodedChunks++
            stream.acceptWaveform(chunk, SAMPLE_RATE)
            while (spotter.isReady(stream)) {
                spotter.decode(stream)
                val keyword = spotter.getResult(stream).keyword
                if (keyword.isNotEmpty()) {
                    // Ready for the next phrase; the same audio never triggers twice.
                    spotter.reset(stream)
                    heard = heard ?: keyword
                }
            }
        }
        return heard
    }

    /** Forgets all audio so far (a new listening session). */
    fun reset() {
        stream.release()
        stream = spotter.createStream("")
        gate = SoundGate()
    }

    fun release() {
        stream.release()
        spotter.release()
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
        const val SAMPLE_RATE = 16000
        const val MODEL_DIR = "wake_word"
        private const val MIN_RMS = 0.002
        private const val NOISE_RATIO = 3.0
        private const val PRE_ROLL_CHUNKS = 3
        private const val HANGOVER_CHUNKS = 15
    }
}

/**
 * Listens for the wake phrase with the microphone. Audio goes into [WakeWordEngine] in memory and is
 * dropped right after; it is never written or sent anywhere.
 *
 * Exactly one microphone owner: at most one listening session (one AudioRecord, one worker thread)
 * exists at a time. [stop] closes the microphone and waits for the worker; [start] never opens a
 * second one while a previous session is still closing.
 *
 * Battery: a cheap loudness check runs on every 100 ms of audio, and the model only runs while there
 * is sound. The model stays loaded between sessions and is freed by [release].
 *
 * [start], [stop] and [release] are called from the main thread.
 */
class WakeWordDetector(
    private val context: Context,
    private val tuning: WakeWordTuning,
    /** Called on the worker thread with the phrase heard, e.g. "HEY_CHILD". */
    private val onDetected: (String) -> Unit,
    /** Called on the worker thread when listening cannot continue. */
    private val onFailure: (Failure) -> Unit,
    /** Called on the worker thread when the microphone really opens (true) or closes (false). */
    private val onRecording: (Boolean) -> Unit = {},
) : WakeEngine {
    enum class Failure {
        /** The model could not be loaded. */
        ENGINE,

        /** The microphone could not be opened or stopped delivering audio. */
        MICROPHONE,

        /** RECORD_AUDIO is not granted. */
        PERMISSION,
    }

    /** One listening session: its own flag, so a closing session can never affect the next one. */
    private class Session {
        @Volatile var active = true
        @Volatile var record: AudioRecord? = null
        @Volatile var recording = false
        var thread: Thread? = null
    }

    private var session: Session? = null

    // Loaded on the first worker, then kept until [release] (loading takes a moment).
    @Volatile private var engine: WakeWordEngine? = null
    private val engineLock = Any()

    /** The audio session of the current recording, to recognise it in recording callbacks. */
    override val audioSessionId: Int get() = session?.record?.audioSessionId ?: 0

    override val isRunning: Boolean get() = session?.active == true

    /** The microphone is open and audio is being checked for the phrase (not just starting). */
    override val isRecording: Boolean get() = session?.let { it.active && it.recording } == true

    override fun start() {
        if (session?.active == true) return
        // A previous session still closing finishes first (bounded), so the microphone has one owner.
        session?.thread?.join(STOP_TIMEOUT_MS)
        val next = Session()
        session = next
        next.thread = Thread({ run(next) }, "WakeWordDetector").apply { start() }
    }

    /** Stops listening and closes the microphone. Returns once the worker has let go of it. */
    override fun stop() {
        val current = session ?: return
        current.active = false
        try {
            // Unblocks a read in progress.
            current.record?.stop()
        } catch (e: IllegalStateException) {
            // Not recording.
        }
        current.thread?.join(STOP_TIMEOUT_MS)
        if (current.thread?.isAlive != true) session = null
    }

    /** Stops and frees the model. */
    override fun release() {
        stop()
        synchronized(engineLock) {
            engine?.release()
            engine = null
        }
    }

    @SuppressLint("MissingPermission") // Checked by the service before starting.
    private fun run(s: Session) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        synchronized(engineLock) {
            val kws = engine ?: try {
                WakeWordEngine(context, tuning).also {
                    engine = it
                    WakeLog.d("model loaded")
                }
            } catch (e: Throwable) {
                WakeLog.w("model failed to load: ${e.javaClass.simpleName}")
                if (s.active) onFailure(Failure.ENGINE)
                s.active = false
                return
            }
            kws.reset()
            record(s, kws)
        }
    }

    @SuppressLint("MissingPermission")
    private fun record(s: Session, kws: WakeWordEngine) {
        if (!s.active) return
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
            if (s.active) onFailure(Failure.PERMISSION)
            s.active = false
            return
        } catch (e: IllegalArgumentException) {
            if (s.active) onFailure(Failure.MICROPHONE)
            s.active = false
            return
        }
        if (audio.state != AudioRecord.STATE_INITIALIZED) {
            audio.release()
            if (s.active) onFailure(Failure.MICROPHONE)
            s.active = false
            return
        }
        s.record = audio
        try {
            // Stopped while the model was loading: never open the microphone at all.
            if (!s.active) return
            audio.startRecording()
            if (audio.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
                if (s.active) onFailure(Failure.MICROPHONE)
                return
            }
            WakeLog.d("audio started")
            WakeLog.d("detector ready")
            WakeLog.d("listening")
            s.recording = true
            onRecording(true)
            listen(s, audio, kws)
        } catch (e: IllegalStateException) {
            if (s.active) onFailure(Failure.MICROPHONE)
        } finally {
            s.active = false
            try {
                audio.stop()
            } catch (e: IllegalStateException) {
                // Already stopped.
            }
            audio.release()
            s.record = null
            if (s.recording) {
                s.recording = false
                onRecording(false)
            }
            WakeLog.d("microphone released")
        }
    }

    private fun listen(s: Session, audio: AudioRecord, kws: WakeWordEngine) {
        val pcm = ShortArray(CHUNK)
        var frames = 0L
        var loudest = 0
        while (s.active) {
            val read = audio.read(pcm, 0, CHUNK)
            if (!s.active) return
            if (read < 0) {
                // ERROR_DEAD_OBJECT etc.: the microphone went away (e.g. audio routing changed).
                WakeLog.w("microphone read failed: $read")
                onFailure(Failure.MICROPHONE)
                return
            }
            if (read == 0) continue
            val samples = FloatArray(read)
            for (i in 0 until read) {
                samples[i] = pcm[i] / 32768f
                if (pcm[i] > loudest) loudest = pcm[i].toInt()
            }
            frames++
            // Proof that real audio arrives (counts and peak level only, never the audio).
            if (frames == 10L || frames % 600L == 0L) {
                WakeLog.d("audio frames received: $frames, peak level: $loudest, model chunks: ${kws.decodedChunks}")
                loudest = 0
            }
            val keyword = kws.accept(samples)
            if (keyword != null) {
                WakeLog.d("wake phrase recognised: $keyword")
                onDetected(keyword)
            }
            // The samples are not kept: each buffer is overwritten by the next read.
        }
    }

    companion object {
        const val SAMPLE_RATE = WakeWordEngine.SAMPLE_RATE
        private const val CHUNK = SAMPLE_RATE / 10
        private const val STOP_TIMEOUT_MS = 1500L

        /** True while a phone or VoIP call is using audio; the wake word pauses for it. */
        fun inCall(audioManager: AudioManager): Boolean = when (audioManager.mode) {
            AudioManager.MODE_IN_CALL, AudioManager.MODE_IN_COMMUNICATION, AudioManager.MODE_RINGTONE -> true
            else -> false
        }
    }
}
