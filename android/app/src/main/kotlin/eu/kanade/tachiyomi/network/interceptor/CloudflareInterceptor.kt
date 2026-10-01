package eu.kanade.tachiyomi.network.interceptor

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.core.content.ContextCompat
import eu.kanade.tachiyomi.network.AndroidCookieJar
import okhttp3.Cookie
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.Interceptor
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The site's Cloudflare check didn't pass on its own. [url] is the site's address, for the app to open for the person to
 * pass it by hand; the clearance they earn is in the same cookie store, so the request then goes through.
 */
class CloudflareChallengeException(val url: String) : IOException("Cloudflare verification required for $url")

/**
 * Aniyomi's: a request answered with Cloudflare's challenge is solved in a hidden WebView, which Cloudflare lets
 * through where it refuses OkHttp, and then repeated with the clearance cookie it earned. When the WebView can't pass
 * (an interactive check) it gives up as a [CloudflareChallengeException].
 */
class CloudflareInterceptor(
    context: Context,
    private val cookieManager: AndroidCookieJar,
    private val defaultUserAgentProvider: () -> String,
) : Interceptor {

    private val appContext = context.applicationContext
    private val executor = ContextCompat.getMainExecutor(appContext)

    /** One solve per site at a time: the requests waiting behind it find its clearance and just go on. */
    private val locks = ConcurrentHashMap<String, Any>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val response = chain.proceed(request)
        if (response.code !in ERROR_CODES || response.header("Server") !in SERVER_CHECK) return response

        response.close()
        val old = clearance(request)
        synchronized(locks.getOrPut(request.url.host) { Any() }) {
            // Someone else solved it while this request waited.
            if (clearance(request).let { it != null && it != old }) return chain.proceed(request)
            cookieManager.remove(request.url, COOKIE_NAMES, 0)
            if (!solve(request, clearance(request))) {
                throw CloudflareChallengeException("${request.url.scheme}://${request.url.host}/")
            }
        }
        return chain.proceed(request)
    }

    private fun clearance(request: Request): Cookie? =
        cookieManager.get(request.url).firstOrNull { it.name == "cf_clearance" }

    /** Loads the page in a WebView until it earns a new clearance cookie; false when it doesn't within 30 seconds. */
    @SuppressLint("SetJavaScriptEnabled")
    private fun solve(request: Request, old: Cookie?): Boolean {
        // OkHttp interceptors are synchronous, so this thread waits for the WebView, which lives on the main one.
        val latch = CountDownLatch(1)
        var webView: WebView? = null
        var challengeFound = false
        var bypassed = false
        val url = request.url.toString()

        executor.execute {
            try {
                webView = WebView(appContext).apply {
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    settings.userAgentString = request.header("User-Agent") ?: defaultUserAgentProvider()
                    webViewClient = object : WebViewClient() {
                        override fun onPageFinished(view: WebView, finished: String) {
                            val cookie = cookieManager.get(url.toHttpUrl()).firstOrNull { it.name == "cf_clearance" }
                            if (cookie != null && cookie != old) {
                                bypassed = true
                                latch.countDown()
                            }
                            // The first load wasn't the challenge, so there's nothing to wait for.
                            if (finished == url && !challengeFound) latch.countDown()
                        }

                        override fun onReceivedError(view: WebView, req: WebResourceRequest, error: WebResourceError) {
                            if (!req.isForMainFrame) return
                            if (error.errorCode in ERROR_CODES) challengeFound = true else latch.countDown()
                        }
                    }
                    loadUrl(url, safeHeaders(request))
                }
            } catch (_: Exception) {
                // No WebView on this device (or it's being updated).
                latch.countDown()
            }
        }

        latch.await(30, TimeUnit.SECONDS)
        executor.execute {
            webView?.run {
                stopLoading()
                destroy()
            }
        }
        return bypassed
    }

    /** Headers the WebView accepts: it refuses some outright (net::ERR_INVALID_ARGUMENT). */
    private fun safeHeaders(request: Request): Map<String, String> = request.headers
        .filter { (name, value) ->
            val n = name.lowercase(Locale.ENGLISH)
            n !in UNSAFE_HEADERS && !n.startsWith("proxy-") && !(n == "connection" && value.lowercase(Locale.ENGLISH) == "upgrade")
        }
        .groupBy({ it.first }) { it.second }
        .mapValues { it.value.first() }

    private companion object {
        val ERROR_CODES = listOf(403, 503)
        val SERVER_CHECK = arrayOf("cloudflare-nginx", "cloudflare")
        val COOKIE_NAMES = listOf("cf_clearance")
        val UNSAFE_HEADERS = setOf(
            "content-length", "host", "trailer", "te", "upgrade", "cookie2", "keep-alive", "transfer-encoding", "set-cookie",
        )
    }
}
