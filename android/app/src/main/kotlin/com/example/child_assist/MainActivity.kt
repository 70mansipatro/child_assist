package com.example.child_assist

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Lets Dart pick the right photo permission (READ_MEDIA_IMAGES vs. storage) per Android version.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "child_assist/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }

        // Documents the user picked with the system file picker (Storage Access Framework).
        // Works only on content URIs the app holds a grant for; never touches file paths and
        // needs no storage permission. Contents are only read on request ("read"), up to a limit.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "child_assist/documents")
            .setMethodCallHandler { call, result ->
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null || uri.scheme != "content") {
                    result.error("invalid_uri", "A content URI is required.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "info" -> inBackground(result) { documentInfo(uri) }
                    "read" -> inBackground(result) { readStart(uri, call.argument<Int>("maxBytes") ?: 0) }
                    "open" -> result.success(
                        openDocument(uri, call.argument<String>("mimeType"), call.argument<Boolean>("anyApp") == true)
                    )
                    "release" -> {
                        releaseGrant(uri)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    /** Runs [work] off the UI thread (provider queries and reads can be slow) and replies on it. */
    private fun inBackground(result: MethodChannel.Result, work: () -> Any?) {
        try {
            io.execute {
                try {
                    val value = work()
                    main.post { result.success(value) }
                } catch (e: Exception) {
                    // No message: it could contain a file name.
                    main.post { result.error("document_error", e.javaClass.simpleName, null) }
                }
            }
        } catch (e: RejectedExecutionException) {
            // The activity is being destroyed.
            result.error("document_error", "Unavailable", null)
        }
    }

    /** Name, size, type and last-modified time, or null if the document is gone or no longer accessible. */
    private fun documentInfo(uri: Uri): Map<String, Any?>? {
        val cursor = try {
            contentResolver.query(uri, null, null, null, null)
        } catch (e: SecurityException) {
            return null
        } catch (e: IllegalArgumentException) {
            return null
        } catch (e: UnsupportedOperationException) {
            return null
        } ?: return null
        cursor.use { c ->
            if (!c.moveToFirst()) return null
            fun column(name: String) = c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }
            return mapOf(
                "name" to column(OpenableColumns.DISPLAY_NAME)?.let(c::getString),
                "size" to column(OpenableColumns.SIZE)?.let(c::getLong),
                "modifiedAt" to column(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    ?.let(c::getLong)?.takeIf { it > 0 },
                "mimeType" to try { contentResolver.getType(uri) } catch (e: Exception) { null },
            )
        }
    }

    /** Up to [maxBytes] from the start of the document, or null if it is gone or no longer accessible. */
    private fun readStart(uri: Uri, maxBytes: Int): ByteArray? {
        val input = try {
            contentResolver.openInputStream(uri)
        } catch (e: FileNotFoundException) {
            return null
        } catch (e: SecurityException) {
            return null
        } ?: return null
        input.use {
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (out.size() < maxBytes) {
                val read = it.read(buffer, 0, minOf(buffer.size, maxBytes - out.size()))
                if (read < 0) break
                out.write(buffer, 0, read)
            }
            return out.toByteArray()
        }
    }

    /** "opened", "noViewer" (no app can show it) or "unavailable". */
    private fun openDocument(uri: Uri, mimeType: String?, anyApp: Boolean): String {
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, if (anyApp || mimeType.isNullOrEmpty()) "*/*" else mimeType)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            startActivity(if (anyApp) Intent.createChooser(view, "Open with") else view)
            "opened"
        } catch (e: ActivityNotFoundException) {
            "noViewer"
        } catch (e: SecurityException) {
            "unavailable"
        }
    }

    private fun releaseGrant(uri: Uri) {
        try {
            contentResolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            // No grant was held for it; nothing to release.
        }
    }
}
