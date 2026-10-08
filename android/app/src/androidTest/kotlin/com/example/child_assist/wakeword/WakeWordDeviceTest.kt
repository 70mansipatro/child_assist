package com.example.child_assist.wakeword

import android.Manifest
import android.content.Context
import android.content.Intent
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Random
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The wake word on a real Android runtime (emulator or phone): the packaged model and native
 * library, the exact engine the service uses, the microphone, and the service itself.
 *
 * The phrases are synthesized speech (two voices, 16 kHz mono) in androidTest/assets/wake_clips,
 * with room noise added. Real voices vary more; this proves the pipeline and the false-positive
 * behaviour, not accuracy for every speaker.
 */
@RunWith(AndroidJUnit4::class)
class WakeWordDeviceTest {
    @get:Rule
    val microphone: GrantPermissionRule = GrantPermissionRule.grant(Manifest.permission.RECORD_AUDIO)

    private val app: Context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val testAssets get() = InstrumentationRegistry.getInstrumentation().context.assets

    private data class Clip(val file: String, val positive: Boolean, val text: String)

    private fun clips(): List<Clip> = testAssets.open("wake_clips/labels.tsv").bufferedReader().readLines()
        .filter { it.isNotBlank() }
        .map { line -> line.split('\t').let { Clip(it[0], it[1] == "pos", it[2]) } }

    /** 16-bit mono PCM from a WAV file, with 1 s of silence before, 2 s after and quiet noise. */
    private fun samples(file: String): FloatArray {
        val bytes = testAssets.open("wake_clips/$file").readBytes()
        // Find the "data" chunk.
        var offset = 12
        var dataStart = -1
        var dataSize = 0
        while (offset + 8 <= bytes.size) {
            val id = String(bytes, offset, 4)
            val size = ByteBuffer.wrap(bytes, offset + 4, 4).order(ByteOrder.LITTLE_ENDIAN).int
            if (id == "data") {
                dataStart = offset + 8
                dataSize = minOf(size, bytes.size - dataStart)
                break
            }
            offset += 8 + size
        }
        check(dataStart > 0) { "no data chunk in $file" }
        val pcm = ByteBuffer.wrap(bytes, dataStart, dataSize).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val speech = FloatArray(pcm.remaining()) { pcm.get(it) / 32768f }
        val rate = WakeWordEngine.SAMPLE_RATE
        val out = FloatArray(rate + speech.size + 2 * rate)
        speech.copyInto(out, rate)
        val noise = Random(file.hashCode().toLong())
        for (i in out.indices) out[i] += (noise.nextGaussian() * 0.003).toFloat()
        return out
    }

    /** Feeds a clip the way the microphone does (100 ms chunks); returns the phrase heard, if any. */
    private fun spot(engine: WakeWordEngine, file: String): String? {
        engine.reset()
        val audio = samples(file)
        val chunk = WakeWordEngine.SAMPLE_RATE / 10
        var heard: String? = null
        var i = 0
        while (i < audio.size) {
            val end = minOf(i + chunk, audio.size)
            heard = heard ?: engine.accept(audio.copyOfRange(i, end))
            i = end
        }
        return heard
    }

    @Test
    fun modelAndNativeLibraryLoadFromTheApk() {
        val names = app.assets.list("wake_word")!!.toSet()
        assertTrue(names.containsAll(listOf("encoder.int8.onnx", "decoder.onnx", "joiner.int8.onnx", "tokens.txt", "keywords.txt")))
        val engine = WakeWordEngine(app, WakeWordTuning())
        // Silence is decoded without detecting anything.
        assertNull(engine.accept(FloatArray(WakeWordEngine.SAMPLE_RATE * 2)))
        engine.release()
    }

    @Test
    fun heyChildAndHiChildAreDetected() {
        val engine = WakeWordEngine(app, WakeWordTuning())
        val positives = clips().filter { it.positive }
        val heard = positives.map { it to spot(engine, it.file) }
        engine.release()
        val report = heard.joinToString("\n") { (c, k) -> "${c.text} -> ${k ?: "missed"}" }
        println("[WakeWordTest] positives:\n$report")
        assertTrue("both phrases are recognised\n$report", heard.any { it.second == "HEY_CHILD" } && heard.any { it.second == "HI_CHILD" })
        val rate = heard.count { it.second != null }.toDouble() / heard.size
        assertTrue("detected ${(rate * 100).toInt()}% of wake phrases\n$report", rate >= 0.8)
    }

    @Test
    fun similarPhrasesDoNotTrigger() {
        val engine = WakeWordEngine(app, WakeWordTuning())
        val negatives = clips().filter { !it.positive }
        val heard = negatives.map { it to spot(engine, it.file) }
        engine.release()
        val report = heard.joinToString("\n") { (c, k) -> "${c.text} -> ${k ?: "no trigger"}" }
        println("[WakeWordTest] negatives:\n$report")
        // "High child" sounds exactly like "Hi Child": documented, not asserted either way.
        val wrong = heard.filter { it.second != null && it.first.text != "High child" }
        assertTrue("false activations:\n$report", wrong.isEmpty())
    }

    @Test
    fun detectorResetsAfterEachTrigger() {
        val engine = WakeWordEngine(app, WakeWordTuning())
        val clip = clips().first { it.positive && it.text == "Hey Child" }
        val first = spot(engine, clip.file)
        // The same audio again, after the reset, is a new detection, and a silence never re-triggers.
        val second = spot(engine, clip.file)
        engine.reset()
        val silence = engine.accept(FloatArray(WakeWordEngine.SAMPLE_RATE * 3))
        engine.release()
        assertEquals(first, second)
        assertNull(silence)
    }

    @Test
    fun microphoneDeliversPcmInTheModelFormat() {
        val min = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        assertTrue("16 kHz mono 16-bit is supported", min > 0)
        val record = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, min * 4)
        assertEquals(AudioRecord.STATE_INITIALIZED, record.state)
        record.startRecording()
        val pcm = ShortArray(1600)
        var total = 0
        repeat(10) { val n = record.read(pcm, 0, pcm.size); if (n > 0) total += n }
        record.stop()
        record.release()
        assertTrue("received $total samples", total >= 1600 * 9)
    }

    @Test
    fun serviceStartsListensPausesAndTurnsOffFromTheNotification() {
        val main = Handler(Looper.getMainLooper())
        fun onMain(block: () -> Unit) {
            val done = CountDownLatch(1)
            main.post { block(); done.countDown() }
            done.await(5, TimeUnit.SECONDS)
        }
        fun waitFor(what: String, seconds: Long = 20, check: () -> Boolean) {
            val until = System.currentTimeMillis() + seconds * 1000
            while (System.currentTimeMillis() < until) {
                var ok = false
                onMain { ok = check() }
                if (ok) return
                Thread.sleep(200)
            }
            throw AssertionError("timed out waiting for: $what (issue=${WakeWordBridge.issue})")
        }

        onMain { WakeWordBridge.saveEnabled(app, "device-test", WakeWordTuning()) }
        WakeWordService.start(app)
        waitFor("service listening") { WakeWordBridge.service?.isListening == true }

        // Child Assist speaking: the microphone closes, and opens again afterwards.
        onMain { WakeWordBridge.service!!.suspend(WakeWordService.REASON_SPEAKING) }
        waitFor("paused while speaking") { WakeWordBridge.service?.isListening == false }
        onMain { WakeWordBridge.service!!.resume(WakeWordService.REASON_SPEAKING) }
        waitFor("listening again") { WakeWordBridge.service?.isListening == true }

        // "Turn off" in the notification.
        app.startService(Intent(app, WakeWordService::class.java).setAction(WakeWordService.ACTION_TURN_OFF))
        waitFor("service stopped") { WakeWordBridge.service == null }
        var enabled = true
        var owner: String? = "x"
        onMain { enabled = WakeWordBridge.isEnabled(app); owner = WakeWordBridge.owner(app) }
        assertFalse("the off state is saved", enabled)
        assertNull("the account is forgotten", owner)
    }

    @Test
    fun serviceRefusesToRunWhenSwitchedOff() {
        val main = Handler(Looper.getMainLooper())
        val done = CountDownLatch(1)
        main.post { WakeWordBridge.clear(app); done.countDown() }
        done.await(5, TimeUnit.SECONDS)
        WakeWordService.start(app)
        Thread.sleep(2000)
        val stopped = CountDownLatch(1)
        var running: WakeWordService? = null
        main.post { running = WakeWordBridge.service; stopped.countDown() }
        stopped.await(5, TimeUnit.SECONDS)
        assertNull("never listens unless switched on", running)
        assertNotNull(app)
    }
}
