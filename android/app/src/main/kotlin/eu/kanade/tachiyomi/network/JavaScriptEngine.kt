package eu.kanade.tachiyomi.network

import android.content.Context
import app.cash.quickjs.QuickJs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Suppress("UNUSED", "UNCHECKED_CAST", "UNUSED_PARAMETER")
class JavaScriptEngine(context: Context) {
    suspend fun <T> evaluate(script: String): T = withContext(Dispatchers.IO) {
        QuickJs.create().use { it.evaluate(script) as T }
    }
}
