package com.example.child_assist

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.telephony.PhoneNumberUtils
import android.telephony.TelephonyManager
import com.example.child_assist.wakeword.WakeWordChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class MainActivity : FlutterActivity() {
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    /** "Hey Child": the on-device wake word service and the app opening for a question. */
    private val wakeWord = WakeWordChannel(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        wakeWord.onActivationIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        wakeWord.onActivationIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        wakeWord.onVisible(true)
    }

    override fun onPause() {
        wakeWord.onVisible(false)
        super.onPause()
    }

    private fun appVersion(): String? = try {
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }
        "${info.versionName}+$code"
    } catch (e: PackageManager.NameNotFoundException) {
        null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        wakeWord.register(flutterEngine)
        // Lets Dart pick the right photo permission (READ_MEDIA_IMAGES vs. storage) per Android version.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "child_assist/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getSdkInt" -> result.success(Build.VERSION.SDK_INT)
                    // Sent with the push-notification registration, e.g. "1.0.0+1".
                    "getAppVersion" -> result.success(appVersion())
                    else -> result.notImplemented()
                }
            }

        // Documents the user picked with the system file picker (Storage Access Framework).
        // Works only on content URIs the app holds a grant for; never touches file paths and
        // needs no storage permission. Contents are only read on request ("read"), up to a limit.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "child_assist/documents")
            .setMethodCallHandler { call, result ->
                // Folders: the user grants one folder in the system folder picker; its documents
                // are then listed every time without asking again (see DocumentFolders).
                when (call.method) {
                    // The system document picker. Each picked document's grant is kept (where
                    // the provider allows it) and checked before it is returned.
                    "pickDocuments" -> {
                        pickDocuments(call.argument<Boolean>("multiple") == true, result)
                        return@setMethodCallHandler
                    }
                    "pickFolder" -> {
                        pickFolder(result)
                        return@setMethodCallHandler
                    }
                    "listFolder", "releaseFolder" -> {
                        val tree = call.argument<String>("tree")?.let(Uri::parse)
                        if (tree == null || tree.scheme != "content") {
                            result.error("invalid_uri", "A content URI is required.", null)
                        } else if (call.method == "listFolder") {
                            inBackground(result) {
                                DocumentFolders.list(
                                    this,
                                    tree,
                                    call.argument<Int>("maxDepth") ?: 4,
                                    call.argument<Int>("maxFiles") ?: 1000,
                                )
                            }
                        } else {
                            DocumentFolders.release(this, tree)
                            result.success(null)
                        }
                        return@setMethodCallHandler
                    }
                }
                val uri = call.argument<String>("uri")?.let(Uri::parse)
                if (uri == null || uri.scheme != "content") {
                    result.error("invalid_uri", "A content URI is required.", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "info" -> inBackground(result) { DocumentAccess.info(this, uri) }
                    "read" -> inBackground(result) { readStart(uri, call.argument<Int>("maxBytes") ?: 0) }
                    // The text of one PDF or DOCX, only when the user asks the assistant about it.
                    "extractText" -> inBackground(result) {
                        DocumentText.extract(
                            this,
                            uri,
                            call.argument<String>("type") ?: "",
                            call.argument<Int>("maxChars") ?: 0,
                        )
                    }
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

        // Chat's confirmed WhatsApp messages: opens WhatsApp (or the share sheet) with the message
        // prefilled. Nothing is ever sent from here: the user taps Send in the app that opens.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "child_assist/share")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "whatsAppInstalled" -> result.success(whatsAppPackage() != null)
                    "openWhatsApp" -> result.success(
                        openWhatsApp(call.argument<String>("phone") ?: "", call.argument<String>("text") ?: "")
                    )
                    "shareText" -> result.success(shareText(call.argument<String>("text") ?: ""))
                    "shareDocument" -> {
                        val uri = call.argument<String>("uri")?.let(Uri::parse)
                        if (uri == null || uri.scheme != "content") {
                            result.error("invalid_uri", "A content URI is required.", null)
                        } else {
                            // Checked first (off the UI thread: a cloud document may be fetched),
                            // so WhatsApp never opens with a document that can no longer be read.
                            val mimeType = call.argument<String>("mimeType")
                            val text = call.argument<String>("text")
                            val phone = call.argument<String>("phone")
                            val toWhatsApp = call.argument<Boolean>("whatsApp") == true
                            inBackground(result, then = { readable ->
                                if (readable == true) shareDocument(uri, mimeType, text, phone, toWhatsApp) else "unavailable"
                            }) {
                                val readable = DocumentAccess.canOpen(this, uri)
                                DocumentAccess.log(this, "share access check ${if (readable) "succeeded" else "failed"}")
                                readable
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        io.shutdown()
        wakeWord.onDestroy()
        super.onDestroy()
    }

    /** The pickers' pending answers; one picker at a time. */
    private var pendingFolder: MethodChannel.Result? = null
    private var pendingDocuments: MethodChannel.Result? = null

    /**
     * Opens the system document picker (Storage Access Framework). Replies with one entry per
     * picked document (see [DocumentAccess.register]), or an empty list if the user cancels.
     */
    private fun pickDocuments(multiple: Boolean, result: MethodChannel.Result) {
        if (pendingDocuments != null || pendingFolder != null) {
            result.error("busy", "The document picker is already open.", null)
            return
        }
        try {
            pendingDocuments = result
            @Suppress("DEPRECATION")
            startActivityForResult(DocumentAccess.pickIntent(multiple), REQUEST_DOCUMENTS)
        } catch (e: ActivityNotFoundException) {
            pendingDocuments = null
            result.error("no_picker", "No document picker is available.", null)
        }
    }

    /** Opens the system folder picker (only when the user asked). Replies {uri, name} or null. */
    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingFolder != null || pendingDocuments != null) {
            result.error("busy", "The folder picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            pendingFolder = result
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQUEST_FOLDER)
        } catch (e: ActivityNotFoundException) {
            pendingFolder = null
            result.success(null)
        }
    }

    @Deprecated("Uses the platform result callback the pickers need.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        when (requestCode) {
            REQUEST_DOCUMENTS -> {
                val result = pendingDocuments ?: return
                pendingDocuments = null
                val uris = if (resultCode == RESULT_OK) DocumentAccess.pickedUris(data) else emptyList()
                if (uris.isEmpty()) {
                    result.success(emptyList<Any>())
                    return
                }
                // The grant flags the picker gave this result: a persistable grant only if offered.
                val flags = data?.flags ?: 0
                inBackground(result) { uris.map { DocumentAccess.register(this, it, flags) } }
            }
            REQUEST_FOLDER -> {
                val result = pendingFolder ?: return
                pendingFolder = null
                val tree = data?.data
                if (resultCode != RESULT_OK || tree == null) {
                    result.success(null)
                    return
                }
                inBackground(result) { DocumentFolders.keep(this, tree) }
            }
        }
    }

    private companion object {
        const val REQUEST_FOLDER = 4711
        const val REQUEST_DOCUMENTS = 4712
    }

    /**
     * Runs [work] off the UI thread (provider queries and reads can be slow) and replies on it,
     * after passing the value through [then] on the UI thread (e.g. to start an activity).
     */
    private fun inBackground(result: MethodChannel.Result, then: (Any?) -> Any? = { it }, work: () -> Any?) {
        try {
            io.execute {
                try {
                    val value = work()
                    main.post {
                        try {
                            result.success(then(value))
                        } catch (e: Exception) {
                            result.error("document_error", e.javaClass.simpleName, null)
                        }
                    }
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

    /** The installed WhatsApp (personal first, then Business), or null. */
    private fun whatsAppPackage(): String? = listOf("com.whatsapp", "com.whatsapp.w4b").firstOrNull { pkg ->
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                packageManager.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                packageManager.getPackageInfo(pkg, 0)
            }
            true
        } catch (e: PackageManager.NameNotFoundException) {
            false
        }
    }

    /**
     * The number in international form without "+", as WhatsApp expects. A number saved without a
     * country code ("98765 43210") gets the SIM's (or the phone's region's) country code.
     */
    private fun whatsAppNumber(raw: String): String {
        val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        val country = listOfNotNull(telephony?.simCountryIso, telephony?.networkCountryIso, Locale.getDefault().country)
            .firstOrNull { it.isNotBlank() }
            ?.uppercase(Locale.ROOT)
        val e164 = country?.let { PhoneNumberUtils.formatNumberToE164(raw, it) }
        return (e164 ?: raw).filter { it.isDigit() }
    }

    /** "opened" or "unavailable" (WhatsApp is not installed or could not be opened). */
    private fun openWhatsApp(phone: String, text: String): String {
        val pkg = whatsAppPackage() ?: return "unavailable"
        val number = whatsAppNumber(phone)
        if (number.length < 7) return "unavailable"
        val intent = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://api.whatsapp.com/send?phone=$number&text=${Uri.encode(text)}"),
        ).apply { setPackage(pkg) }
        return try {
            startActivity(intent)
            "opened"
        } catch (e: ActivityNotFoundException) {
            "unavailable"
        }
    }

    /** Opens the system share sheet with [text]; the user picks the app and sends it there. */
    private fun shareText(text: String): String {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        return try {
            startActivity(Intent.createChooser(send, "Share with"))
            "opened"
        } catch (e: ActivityNotFoundException) {
            "unavailable"
        }
    }

    /**
     * Shares one document the user added (a content URI this app holds a grant for), either straight
     * to the contact's WhatsApp chat or through the share sheet. The receiving app gets read access
     * to this one file only.
     */
    private fun shareDocument(uri: Uri, mimeType: String?, text: String?, phone: String?, toWhatsApp: Boolean): String {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = if (mimeType.isNullOrEmpty()) "*/*" else mimeType
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri(null, uri)
            if (!text.isNullOrEmpty()) putExtra(Intent.EXTRA_TEXT, text)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            if (toWhatsApp) {
                val pkg = whatsAppPackage() ?: return "unavailable"
                send.setPackage(pkg)
                // Opens the chat with this contact directly instead of WhatsApp's contact picker.
                if (!phone.isNullOrEmpty()) send.putExtra("jid", "${whatsAppNumber(phone)}@s.whatsapp.net")
                startActivity(send)
            } else {
                startActivity(Intent.createChooser(send, "Share with"))
            }
            "opened"
        } catch (e: ActivityNotFoundException) {
            "unavailable"
        } catch (e: SecurityException) {
            "unavailable"
        }
    }
}
