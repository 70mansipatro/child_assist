package com.example.child_assist

import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Picking and checking single documents through the Storage Access Framework. Everything goes
 * through [android.content.ContentResolver] with the content URI the system picker returned:
 * never `File(uri.path)`, never a guessed filesystem path. That is what makes documents from
 * Downloads, internal storage, Google Drive and other DocumentsProviders work the same way.
 */
object DocumentAccess {
    /** PDF, DOC, DOCX and TXT, for the system picker's filter. */
    val MIME_TYPES = arrayOf(
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/plain",
    )

    /** The system document picker (ACTION_OPEN_DOCUMENT), asking for a grant that can be kept. */
    fun pickIntent(multiple: Boolean): Intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, MIME_TYPES)
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
    }

    /** The content URIs in a picker result (one, or several from a multiple selection). */
    fun pickedUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val uris = ArrayList<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add) }
        data.data?.let(uris::add)
        return uris.filter { it.scheme == "content" }.distinct()
    }

    /**
     * Keeps access to one picked document across restarts where the provider allows it, then
     * checks it really can be read. Returns {uri, name, mimeType, size, modifiedAt, persisted,
     * readable}. "persisted" is false for providers that only grant access until the app closes
     * (some third-party file managers); "readable" is false when the document could not be
     * opened right now (e.g. a Google Drive file while offline).
     */
    fun register(context: Context, uri: Uri, resultFlags: Int): Map<String, Any?> {
        log(context, "picker URI received (${uri.authority})")
        val persisted = keep(context, uri, resultFlags)
        log(context, if (persisted) "persistable permission granted" else "persistable permission NOT available")
        val info = info(context, uri)
        val readable = info != null && canOpen(context, uri)
        log(context, "ContentResolver open ${if (readable) "succeeded" else "failed"}")
        return (info ?: emptyMap()) + mapOf(
            "uri" to uri.toString(),
            "persisted" to persisted,
            "readable" to readable,
        )
    }

    /** Takes the persistable read grant when offered and confirms Android actually kept it. */
    private fun keep(context: Context, uri: Uri, resultFlags: Int): Boolean {
        if (resultFlags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION != 0) {
            try {
                context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (e: SecurityException) {
                // The provider does not support it; access lasts until the app process ends.
            }
        }
        return isPersisted(context, uri)
    }

    fun isPersisted(context: Context, uri: Uri): Boolean =
        context.contentResolver.persistedUriPermissions.any { it.uri == uri && it.isReadPermission }

    /** Name, size, type and last-modified time, or null if the document is gone or no longer accessible. */
    fun info(context: Context, uri: Uri): Map<String, Any?>? {
        val resolver = context.contentResolver
        val cursor = try {
            resolver.query(uri, null, null, null, null)
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
                "mimeType" to try { resolver.getType(uri) } catch (e: Exception) { null },
            )
        }
    }

    /**
     * Whether the document's stream can be opened right now. For a cloud provider this may
     * fetch the file, so it runs off the UI thread and only when needed (picking, sharing).
     */
    fun canOpen(context: Context, uri: Uri): Boolean = try {
        context.contentResolver.openInputStream(uri)?.use { true } ?: false
    } catch (e: FileNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    } catch (e: IOException) {
        false
    } catch (e: IllegalArgumentException) {
        false
    } catch (e: IllegalStateException) {
        false
    }

    /**
     * Diagnostics for debug builds only. Never logs document contents, names or full URIs:
     * at most the provider's authority (e.g. "com.android.providers.downloads.documents").
     */
    fun log(context: Context, message: String) {
        if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            Log.d("ChildAssist", "[Documents] $message")
        }
    }
}
