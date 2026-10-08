package com.example.child_assist.wakeword

import android.content.Context
import android.content.pm.ApplicationInfo
import android.util.Log

/**
 * Wake-word diagnostics, e.g. "[WakeWord] listening". Debug builds only, plus warnings in all
 * builds. Only fixed event names and counts are ever logged: never audio, transcripts, tokens,
 * account ids or anything the user said.
 */
object WakeLog {
    private const val TAG = "WakeWord"
    @Volatile private var debug = false

    fun init(context: Context) {
        debug = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    fun d(event: String) {
        if (debug) Log.i(TAG, "[WakeWord] $event")
    }

    fun w(event: String) {
        Log.w(TAG, "[WakeWord] $event")
    }
}
