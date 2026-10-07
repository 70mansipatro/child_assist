package com.example.child_assist

import android.content.Context
import android.net.Uri
import android.util.Xml
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
import com.tom_roush.pdfbox.text.PDFTextStripper
import org.xmlpull.v1.XmlPullParser
import java.io.BufferedInputStream
import java.io.FileNotFoundException
import java.io.FilterInputStream
import java.io.InputStream
import java.util.zip.ZipInputStream

/**
 * Extracts the readable text of ONE document the user picked, on the phone, for the assistant to
 * answer a question about it. Reads only through the document's content URI (a grant the user
 * gave in the system picker), never a file path. Nothing is written anywhere and nothing is
 * logged: the text goes back to Dart, which sends it for that one question only.
 *
 * Result: null when the document is gone or no longer accessible, otherwise a map with
 * "status": "ok" (with "text" and "truncated"), "encrypted", "unsupported" or "unreadable".
 */
object DocumentText {
    /** Upper bound on the bytes read from inside a DOCX, against oversized or hostile files. */
    private const val MAX_DOCX_XML_BYTES = 64L * 1024 * 1024

    /** PDF parsing memory before PdfBox spills to a temp file in the app's own cache. */
    private const val PDF_MEMORY_BYTES = 32L * 1024 * 1024

    @Volatile
    private var pdfBoxReady = false

    fun extract(context: Context, uri: Uri, type: String, maxChars: Int): Map<String, Any?>? {
        if (type != "PDF" && type != "DOCX") return mapOf("status" to "unsupported")
        val input = try {
            context.contentResolver.openInputStream(uri)
        } catch (e: FileNotFoundException) {
            return null
        } catch (e: SecurityException) {
            return null
        } ?: return null
        return input.use {
            try {
                if (type == "PDF") pdf(context, it, maxChars) else docx(it, maxChars)
            } catch (e: InvalidPasswordException) {
                mapOf("status" to "encrypted")
            } catch (e: Exception) {
                // A damaged or unexpected file. No message: it could contain document text.
                mapOf("status" to "unreadable")
            } catch (e: OutOfMemoryError) {
                mapOf("status" to "unreadable")
            }
        }
    }

    private fun ok(text: StringBuilder, truncated: Boolean) =
        mapOf("status" to "ok", "text" to text.toString(), "truncated" to truncated)

    private fun pdf(context: Context, input: InputStream, maxChars: Int): Map<String, Any?> {
        if (!pdfBoxReady) {
            PDFBoxResourceLoader.init(context.applicationContext)
            pdfBoxReady = true
        }
        PDDocument.load(input, MemoryUsageSetting.setupMixed(PDF_MEMORY_BYTES)).use { doc ->
            val stripper = PDFTextStripper().apply { sortByPosition = true }
            val out = StringBuilder()
            // Page by page, so a huge document stops as soon as there is enough text.
            for (page in 1..doc.numberOfPages) {
                stripper.startPage = page
                stripper.endPage = page
                val text = stripper.getText(doc)
                if (out.length + text.length > maxChars) {
                    out.append(text, 0, maxChars - out.length)
                    return ok(out, true)
                }
                out.append(text)
            }
            return ok(out, false)
        }
    }

    /** The text of word/document.xml: runs of w:t, with paragraph, tab and line breaks kept. */
    private fun docx(input: InputStream, maxChars: Int): Map<String, Any?> {
        ZipInputStream(BufferedInputStream(input)).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                if (entry.name == "word/document.xml") return docxXml(Capped(zip, MAX_DOCX_XML_BYTES), maxChars)
                entry = zip.nextEntry
            }
        }
        return mapOf("status" to "unreadable")
    }

    private fun docxXml(xml: InputStream, maxChars: Int): Map<String, Any?> {
        // Android's pull parser does not fetch external entities or DTDs.
        val parser = Xml.newPullParser().apply {
            setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false)
            setInput(xml, null)
        }
        val out = StringBuilder()
        var inText = false
        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            when (event) {
                XmlPullParser.START_TAG -> when (parser.name) {
                    "w:t" -> inText = true
                    "w:tab" -> out.append('\t')
                    "w:br", "w:cr" -> out.append('\n')
                }
                XmlPullParser.END_TAG -> when (parser.name) {
                    "w:t" -> inText = false
                    "w:p" -> out.append('\n')
                }
                XmlPullParser.TEXT -> if (inText) out.append(parser.text)
            }
            if (out.length > maxChars) {
                out.setLength(maxChars)
                return ok(out, true)
            }
            event = try {
                parser.next()
            } catch (e: Capped.LimitReached) {
                return ok(out, true)
            }
        }
        return ok(out, false)
    }

    /** Stops reading after [limit] bytes. */
    private class Capped(input: InputStream, private val limit: Long) : FilterInputStream(input) {
        class LimitReached : RuntimeException()

        private var count = 0L

        override fun read(): Int {
            if (count >= limit) throw LimitReached()
            val b = super.read()
            if (b >= 0) count++
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (count >= limit) throw LimitReached()
            val n = super.read(b, off, minOf(len.toLong(), limit - count).toInt())
            if (n > 0) count += n
            return n
        }

        // Closing the entry stream would close the whole zip; the zip is closed by its owner.
        override fun close() {}
    }
}
