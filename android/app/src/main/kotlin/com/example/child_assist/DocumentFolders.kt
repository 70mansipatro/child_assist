package com.example.child_assist

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document

/**
 * Folders the user granted in the system folder picker (Storage Access Framework,
 * ACTION_OPEN_DOCUMENT_TREE). This is the most Android lets an app see of other apps' documents
 * without "all files access": once a folder is granted, its PDF, Word and text files (and those in
 * its subfolders) can be listed every time, with no picker, until the user removes the access.
 *
 * Only content URIs from the grant are used: never file paths, never other apps' private storage.
 * Nothing is logged (file names are private).
 */
object DocumentFolders {
    private val SUPPORTED_EXTENSIONS = setOf("pdf", "doc", "docx", "txt")
    private val SUPPORTED_MIME_TYPES = setOf(
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "text/plain",
    )

    private fun granted(context: Context, tree: Uri): Boolean =
        context.contentResolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission }

    /** Keeps read access to [tree] across restarts and returns {uri, name}. */
    fun keep(context: Context, tree: Uri): Map<String, Any?> {
        context.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return mapOf("uri" to tree.toString(), "name" to name(context, tree))
    }

    fun release(context: Context, tree: Uri) {
        try {
            context.contentResolver.releasePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            // No grant was held; nothing to release.
        }
    }

    private fun name(context: Context, tree: Uri): String? = try {
        val root = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        context.contentResolver.query(root, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
        }
    } catch (e: Exception) {
        null
    }

    /**
     * The supported documents in [tree] and its subfolders (up to [maxDepth] levels, at most
     * [maxFiles]), or null when the access was removed or the folder no longer exists.
     * Each: {uri, name, mimeType, size, modifiedAt}; "folderName" and "truncated" describe the
     * whole listing.
     */
    fun list(context: Context, tree: Uri, maxDepth: Int, maxFiles: Int): Map<String, Any?>? {
        if (!granted(context, tree)) return null
        val rootId = try {
            DocumentsContract.getTreeDocumentId(tree)
        } catch (e: IllegalArgumentException) {
            return null
        }
        val projection = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
        )
        val documents = ArrayList<Map<String, Any?>>()
        var truncated = false
        val pending = ArrayDeque<Pair<String, Int>>()
        pending.add(rootId to 0)
        var first = true
        while (pending.isNotEmpty() && !truncated) {
            val (folderId, depth) = pending.removeFirst()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, folderId)
            val cursor = try {
                context.contentResolver.query(children, projection, null, null, null)
            } catch (e: Exception) {
                // The granted folder itself is gone or no longer readable: report it as such.
                if (first) return null
                null
            }
            first = false
            cursor?.use { c ->
                while (c.moveToNext()) {
                    val id = c.getString(0) ?: continue
                    val name = c.getString(1) ?: continue
                    if (name.startsWith(".")) continue
                    val mime = c.getString(2)
                    if (mime == Document.MIME_TYPE_DIR) {
                        if (depth + 1 < maxDepth) pending.add(id to depth + 1)
                        continue
                    }
                    if (!supported(name, mime)) continue
                    if (documents.size >= maxFiles) {
                        truncated = true
                        break
                    }
                    documents.add(
                        mapOf(
                            "uri" to DocumentsContract.buildDocumentUriUsingTree(tree, id).toString(),
                            "name" to name,
                            "mimeType" to mime,
                            "size" to if (c.isNull(3)) null else c.getLong(3),
                            "modifiedAt" to if (c.isNull(4)) null else c.getLong(4).takeIf { it > 0 },
                        )
                    )
                }
            }
        }
        return mapOf(
            "documents" to documents,
            "truncated" to truncated,
            "folderName" to name(context, tree),
        )
    }

    private fun supported(name: String, mime: String?): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in SUPPORTED_EXTENSIONS || mime in SUPPORTED_MIME_TYPES
    }
}
