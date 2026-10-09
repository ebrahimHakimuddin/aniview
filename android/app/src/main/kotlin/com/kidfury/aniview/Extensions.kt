package com.kidfury.aniview

import android.app.Application
import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import dalvik.system.PathClassLoader
import eu.kanade.tachiyomi.animesource.AnimeSource
import eu.kanade.tachiyomi.animesource.AnimeSourceFactory
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.animesource.online.AnimeHttpSource
import eu.kanade.tachiyomi.animesource.online.ParsedAnimeHttpSource
import eu.kanade.tachiyomi.network.JavaScriptEngine
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.interceptor.CloudflareChallengeException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.addSingletonFactory
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Aniyomi anime extensions: APKs from a repo the user added, kept in the app's files and loaded into the app
 * (eu.kanade.tachiyomi.* is the API they're built against). Dart reaches them over 'aniview/extensions'.
 */
class Extensions(private val context: Context, engine: FlutterEngine) {
    private val dir = File(context.filesDir, "extensions").apply { mkdirs() }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, _ -> })

    init {
        provide(context.applicationContext as Application)
        MethodChannel(engine.dartExecutor.binaryMessenger, "aniview/extensions").setMethodCallHandler { call, result ->
            scope.launch {
                // Throwable: an extension built for another lib fails with LinkageErrors, which must not crash the app.
                val reply = try {
                    Result.success(handle(call))
                } catch (e: Throwable) {
                    Result.failure(e)
                }
                withContext(Dispatchers.Main) {
                    reply.fold(result::success) { e ->
                        // An extension may wrap what its request threw, so look through the causes.
                        val challenge = generateSequence<Throwable>(e) { it.cause }
                            .filterIsInstance<CloudflareChallengeException>().firstOrNull()
                        if (challenge != null) {
                            result.error("cloudflare", challenge.message, challenge.url)
                        } else {
                            result.error("extension", e.message ?: e.toString(), null)
                        }
                    }
                }
            }
        }
    }

    /**
     * The shows and episodes as the extensions made them, by source id and url. Extensions keep more in them than the
     * app shows (details they read back later, an episode's number), so the same objects are handed back to them.
     */
    private val animes = ConcurrentHashMap<String, SAnime>()
    private val episodes = ConcurrentHashMap<String, SEpisode>()

    private fun <T> ConcurrentHashMap<String, T>.keep(key: String, value: T) {
        // A browsing session's worth; the rest is dropped rather than grown without end.
        if (size > 3000) clear()
        put(key, value)
    }

    private suspend fun handle(call: MethodCall): Any? {
        fun arg(name: String) = call.argument<String>(name)!!
        fun source() = loaded()[arg("id")]?.source as? AnimeHttpSource
            ?: throw IllegalStateException("That extension isn't installed")
        return when (call.method) {
            "list" -> loaded().values.map { it.toMap() }
            "install" -> install(File(arg("path")), arg("fingerprint")).map { it.toMap() }
            "uninstall" -> uninstall(arg("pkg")).let { null }
            "search" -> source().run { getSearchAnime(1, arg("query"), getFilterList()) }.animes.map {
                animes.keep("${arg("id")}|${it.url}", it)
                mapOf("url" to it.url, "title" to it.title, "thumbnail" to it.thumbnail_url)
            }
            "episodes" -> source().getEpisodeList(animes["${arg("id")}|${arg("url")}"] ?: anime(arg("url"), arg("title"))).map {
                episodes.keep("${arg("id")}|${it.url}", it)
                mapOf(
                    "url" to it.url,
                    "name" to it.name,
                    "number" to it.episode_number.toDouble(),
                    "preview" to it.preview_url,
                    "summary" to it.summary,
                )
            }
            "videos" -> videos(
                source(),
                episodes["${arg("id")}|${arg("url")}"] ?: episode(arg("url"), arg("name")),
            ).map(::videoMap)
            else -> throw NotImplementedError(call.method)
        }
    }

    private class Loaded(val pkg: String, val version: String, val source: AnimeSource) {
        fun toMap() = mapOf(
            "id" to source.id.toString(),
            "name" to source.name,
            "lang" to source.lang,
            "baseUrl" to (source as? AnimeHttpSource)?.baseUrl,
            "pkg" to pkg,
            "version" to version,
        )
    }

    /** The installed extensions' sources by id, loaded on first use. */
    private fun loaded(): ConcurrentHashMap<String, Loaded> = synchronized(Companion) {
        if (sources == null) {
            sources = ConcurrentHashMap<String, Loaded>().apply {
                dir.listFiles { f -> f.extension == "apk" }.orEmpty().forEach { apk ->
                    try {
                        load(apk).forEach { put(it.source.id.toString(), it) }
                    } catch (_: Throwable) {
                        // Left out until it's updated or removed.
                    }
                }
            }
        }
        sources!!
    }

    /**
     * Installs [apk] once it's signed with the repo's key ([fingerprint]: its certificate's SHA-256). An update replaces
     * the installed version only after the new one has loaded, so a bad update leaves the working one in place.
     */
    private fun install(apk: File, fingerprint: String): List<Loaded> {
        val info = archiveInfo(apk, signatures = true)
        val signers = signers(info)
        check(signers.isNotEmpty() && signers.all { it == fingerprint.lowercase() }) {
            "${info.packageName} isn't signed by the repo's key"
        }
        val target = File(dir, "${info.packageName}.apk")
        // Not ".apk", so it isn't taken for an installed extension while it waits.
        val staged = File(dir, "${info.packageName}.new")
        staged.delete()
        apk.copyTo(staged)
        // Android 14 only loads code from files nothing can write to.
        staged.setReadOnly()
        try {
            load(staged)
        } catch (e: Throwable) {
            staged.delete()
            throw e
        }
        loaded().values.removeAll { it.pkg == info.packageName }
        check(staged.renameTo(target)) { "Couldn't replace ${info.packageName}" }
        return try {
            load(target).onEach { loaded()[it.source.id.toString()] = it }
        } catch (e: Throwable) {
            target.delete()
            throw e
        }
    }

    private fun uninstall(pkg: String) {
        loaded().values.removeAll { it.pkg == pkg }
        File(dir, "$pkg.apk").delete()
    }

    private fun load(apk: File): List<Loaded> {
        val info = archiveInfo(apk, signatures = false)
        val meta = info.applicationInfo!!.metaData
        val version = info.versionName!!
        // The lib version is the version name's major part; lib 14 and 16 are what the API here implements.
        val lib = version.substringBeforeLast('.').toDouble()
        check(lib >= 14 && lib < 17) { "${info.packageName} needs extensions-lib $lib" }
        val loader = ChildFirstPathClassLoader(apk.path, null, context.classLoader)
        return meta.getString("tachiyomi.animeextension.class")!!.split(';').map { it.trim() }.flatMap { name ->
            val className = if (name.startsWith('.')) info.packageName + name else name
            fun create(loader: ClassLoader) =
                when (val obj = Class.forName(className, false, loader).getDeclaredConstructor().newInstance()) {
                    is AnimeSource -> listOf(obj)
                    is AnimeSourceFactory -> obj.createSources()
                    else -> error("Unknown source class $className")
                }
            try {
                create(loader)
            } catch (_: LinkageError) {
                // As Aniyomi does: one that bundles a class the app has too links against the app's instead.
                create(PathClassLoader(apk.path, null, context.classLoader))
            }
        }.map { Loaded(info.packageName, version, it) }
    }

    private fun archiveInfo(apk: File, signatures: Boolean): PackageInfo {
        val signing = when {
            !signatures -> 0
            Build.VERSION.SDK_INT >= 28 -> PackageManager.GET_SIGNING_CERTIFICATES
            else -> @Suppress("DEPRECATION") PackageManager.GET_SIGNATURES
        }
        return context.packageManager.getPackageArchiveInfo(apk.path, PackageManager.GET_META_DATA or signing)
            ?.apply { applicationInfo?.run { sourceDir = apk.path; publicSourceDir = apk.path } }
            ?: error("Not an Android package")
    }

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): List<String> {
        val certs = if (Build.VERSION.SDK_INT >= 28) {
            info.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
        } else {
            info.signatures
        }
        val sha = MessageDigest.getInstance("SHA-256")
        return certs.orEmpty().map { cert -> sha.digest(cert.toByteArray()).joinToString("") { "%02x".format(it) } }
    }

    private fun anime(url: String, title: String) = SAnime.create().also {
        it.url = url
        it.title = title
    }

    private fun episode(url: String, name: String) = SEpisode.create().also {
        it.url = url
        it.name = name
    }

    /** Every playable video, the way Aniyomi's player gets them: per hoster on lib 16, one flat list on lib 14. */
    private suspend fun videos(source: AnimeHttpSource, episode: SEpisode): List<Video> = withContext(Dispatchers.IO) {
        // A few requests at a time: dozens at once to one site get the app rate-limited or blocked.
        val gate = Semaphore(4)
        val videos = if (hasHosters(source)) {
            with(source) { getHosterList(episode).sortHosters() }.map { hoster ->
                async {
                    try {
                        gate.withPermit { hoster.videoList ?: source.getVideoList(hoster) }
                    } catch (_: Exception) {
                        emptyList()
                    }
                }
            }.awaitAll().flatten()
        } else {
            source.getVideoList(episode)
        }
        // Its pick first, which Aniyomi plays: lib 16 marks it rather than sorting it there.
        with(source) { videos.sortVideos() }.sortedByDescending { it.preferred }.map { video ->
            async {
                try {
                    gate.withPermit {
                        // Lib 14 leaves "null" when the url is only on the video's page; lib 16 may resolve lazily.
                        val withUrl = if (video.videoUrl == "null") video.copy(videoUrl = source.getVideoUrl(video)) else video
                        if (withUrl.initialized) withUrl else source.resolveVideo(withUrl)
                    }
                } catch (_: Exception) {
                    null
                }
            }
        }.awaitAll().filterNotNull().filter { it.videoUrl.startsWith("http") } // not magnet: links or "null"
            // One without headers of its own plays with the source's (its User-Agent, Referer), as in Aniyomi.
            .map { if (it.headers == null) it.copy(headers = source.headers) else it }
    }

    /** Whether the extension uses lib 16's hosters, as Aniyomi tells: it declares one of their methods itself. */
    private fun hasHosters(source: AnimeHttpSource): Boolean {
        var current: Class<*>? = source.javaClass
        while (current != null && current != AnimeHttpSource::class.java && current != ParsedAnimeHttpSource::class.java) {
            if (current.declaredMethods.any { it.name in hosterMethods }) return true
            current = current.superclass
        }
        return false
    }

    private fun videoMap(video: Video) = mapOf(
        "title" to video.videoTitle,
        "url" to video.videoUrl,
        "headers" to video.headers?.toMap(),
        "subtitles" to video.subtitleTracks.map { mapOf("url" to it.url, "lang" to it.lang) },
        "timestamps" to video.timestamps.map {
            mapOf("start" to it.start, "end" to it.end, "name" to it.name, "type" to it.type.name)
        },
    )

    companion object {
        private val hosterMethods = setOf("getHosterList", "hosterListRequest", "hosterListParse")
        private var sources: ConcurrentHashMap<String, Loaded>? = null
        private var provided = false

        /** What extensions ask Injekt for, as Aniyomi registers it. */
        private fun provide(app: Application) = synchronized(this) {
            if (provided) return
            provided = true
            Injekt.addSingleton<Application>(app)
            Injekt.addSingletonFactory { NetworkHelper(app) }
            Injekt.addSingletonFactory { JavaScriptEngine(app) }
            Injekt.addSingletonFactory {
                Json {
                    ignoreUnknownKeys = true
                    explicitNulls = false
                }
            }
        }
    }
}

/**
 * Aniyomi's: the extension's own classes before the app's, so an obfuscated class name in an extension can't
 * resolve to an unrelated class of the app.
 */
private class ChildFirstPathClassLoader(
    dexPath: String,
    librarySearchPath: String?,
    parent: ClassLoader,
) : PathClassLoader(dexPath, librarySearchPath, parent) {
    private val systemClassLoader: ClassLoader? = getSystemClassLoader()

    override fun loadClass(name: String?, resolve: Boolean): Class<*> {
        var c = findLoadedClass(name)
        if (c == null && systemClassLoader != null) {
            try {
                c = systemClassLoader.loadClass(name)
            } catch (_: ClassNotFoundException) {}
        }
        if (c == null) {
            c = try {
                findClass(name)
            } catch (_: ClassNotFoundException) {
                super.loadClass(name, resolve)
            }
        }
        if (resolve) resolveClass(c)
        return c
    }
}
