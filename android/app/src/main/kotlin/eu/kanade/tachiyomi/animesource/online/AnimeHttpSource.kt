@file:Suppress("DEPRECATION")

package eu.kanade.tachiyomi.animesource.online

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import eu.kanade.tachiyomi.animesource.AnimeCatalogueSource
import eu.kanade.tachiyomi.animesource.model.AnimeFilterList
import eu.kanade.tachiyomi.animesource.model.AnimesPage
import eu.kanade.tachiyomi.animesource.model.Hoster
import eu.kanade.tachiyomi.animesource.model.SAnime
import eu.kanade.tachiyomi.animesource.model.SEpisode
import eu.kanade.tachiyomi.animesource.model.ThumbnailInfo
import eu.kanade.tachiyomi.animesource.model.Video
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.awaitSuccess
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import uy.kohesive.injekt.injectLazy
import java.net.URI
import java.net.URISyntaxException
import java.security.MessageDigest

/**
 * A simple implementation for sources from a website: Aniyomi's, with every RxJava `fetch*` path turned into its
 * suspend equivalent (extensions only ever override the request/parse helpers or the suspend methods).
 */
abstract class AnimeHttpSource : AnimeCatalogueSource {
    protected val network: NetworkHelper by injectLazy()

    /**
     * Base url of the website without the trailing slash, like: http://mysite.com
     */
    abstract val baseUrl: String

    open fun getHomeUrl(): String = baseUrl

    /**
     * Version id used to generate the source id. If the site completely changes and urls are
     * incompatible, you may increase this value and it'll be considered as a new source.
     */
    open val versionId: Int = 1

    override val id: Long by lazy { generateId(name, lang, versionId) }

    val headers: Headers by lazy { headersBuilder().build() }

    open val client: OkHttpClient get() = network.client

    /**
     * The first 16 hex characters (64 bits) of the MD5 of `"${name.lowercase()}/$lang/$versionId"`, sign bit cleared.
     */
    @Suppress("MemberVisibilityCanBePrivate")
    protected fun generateId(name: String, lang: String, versionId: Int): Long {
        val key = "${name.lowercase()}/$lang/$versionId"
        val bytes = MessageDigest.getInstance("MD5").digest(key.toByteArray())
        return (0..7).map { bytes[it].toLong() and 0xff shl 8 * (7 - it) }.reduce(Long::or) and Long.MAX_VALUE
    }

    protected open fun headersBuilder(): Headers.Builder = Headers.Builder().apply {
        add("User-Agent", network.defaultUserAgentProvider())
    }

    override fun toString(): String = "$name (${lang.uppercase()})"

    override suspend fun getPopularAnime(page: Int): AnimesPage =
        client.newCall(popularAnimeRequest(page)).awaitSuccess().let { popularAnimeParse(it) }

    protected open fun popularAnimeRequest(page: Int): Request = throw UnsupportedOperationException()

    protected open fun popularAnimeParse(response: Response): AnimesPage = throw UnsupportedOperationException()

    override suspend fun getSearchAnime(page: Int, query: String, filters: AnimeFilterList): AnimesPage =
        client.newCall(searchAnimeRequest(page, query, filters)).awaitSuccess().let { searchAnimeParse(it) }

    protected open fun searchAnimeRequest(
        page: Int,
        query: String,
        filters: AnimeFilterList,
    ): Request = throw UnsupportedOperationException()

    protected open fun searchAnimeParse(response: Response): AnimesPage = throw UnsupportedOperationException()

    override suspend fun getLatestUpdates(page: Int): AnimesPage =
        client.newCall(latestUpdatesRequest(page)).awaitSuccess().let { latestUpdatesParse(it) }

    protected open fun latestUpdatesRequest(page: Int): Request = throw UnsupportedOperationException()

    protected open fun latestUpdatesParse(response: Response): AnimesPage = throw UnsupportedOperationException()

    override suspend fun getAnimeDetails(anime: SAnime): SAnime =
        client.newCall(animeDetailsRequest(anime)).awaitSuccess()
            .let { response -> animeDetailsParse(response).apply { initialized = true } }

    open fun animeDetailsRequest(anime: SAnime): Request = GET(baseUrl + anime.url, headers)

    protected open fun animeDetailsParse(response: Response): SAnime = throw UnsupportedOperationException()

    override suspend fun getEpisodeList(anime: SAnime): List<SEpisode> =
        client.newCall(episodeListRequest(anime)).awaitSuccess().let { episodeListParse(it) }

    protected open fun episodeListRequest(anime: SAnime): Request = GET(baseUrl + anime.url, headers)

    protected open fun episodeListParse(response: Response): List<SEpisode> = throw UnsupportedOperationException()

    /** From the related-anime fork of the lib (yuzono's extensions override and call it). */
    protected open fun relatedAnimeListRequest(anime: SAnime): Request = GET(baseUrl + anime.url, headers)

    protected open fun relatedAnimeListParse(response: Response): List<SAnime> = throw UnsupportedOperationException()

    protected open fun episodeVideoParse(response: Response): SEpisode = throw UnsupportedOperationException()

    /** @since extensions-lib 16 */
    override suspend fun getSeasonList(anime: SAnime): List<SAnime> =
        client.newCall(seasonListRequest(anime)).awaitSuccess().let { seasonListParse(it) }

    protected open fun seasonListRequest(anime: SAnime): Request = GET(baseUrl + anime.url, headers)

    protected open fun seasonListParse(response: Response): List<SAnime> = throw UnsupportedOperationException()

    /** The hosters for an episode, the preferred one first. @since extensions-lib 16 */
    override suspend fun getHosterList(episode: SEpisode): List<Hoster> =
        client.newCall(hosterListRequest(episode)).awaitSuccess().let { hosterListParse(it) }

    protected open fun hosterListRequest(episode: SEpisode): Request = GET(baseUrl + episode.url, headers)

    protected open fun hosterListParse(response: Response): List<Hoster> = throw UnsupportedOperationException()

    /** @since extensions-lib 16 */
    override suspend fun getVideoList(hoster: Hoster): List<Video> =
        client.newCall(videoListRequest(hoster)).awaitSuccess().let { videoListParse(it, hoster) }

    protected open fun videoListRequest(hoster: Hoster): Request = GET(hoster.hosterUrl, headers)

    protected open fun videoListParse(
        response: Response,
        hoster: Hoster,
    ): List<Video> = throw UnsupportedOperationException()

    /** The resolved video, or null on failure. @since extensions-lib 16 */
    open suspend fun resolveVideo(video: Video): Video? = video

    /** @since extensions-lib 17 */
    open suspend fun getVideoThumbnails(video: Video): ThumbnailInfo? = null

    /** @since extensions-lib 17 */
    open suspend fun getImageTile(url: String): Bitmap? =
        client.newCall(GET(url, headers)).execute().body.byteStream().use { BitmapFactory.decodeStream(it) }

    override suspend fun getVideoList(episode: SEpisode): List<Video> =
        client.newCall(videoListRequest(episode)).awaitSuccess().let { videoListParse(it) }

    protected open fun videoListRequest(episode: SEpisode): Request = GET(baseUrl + episode.url, headers)

    protected open fun videoListParse(response: Response): List<Video> = throw UnsupportedOperationException()

    /** @since extensions-lib 16 */
    open fun List<Hoster>.sortHosters(): List<Hoster> = this

    /** @since extensions-lib 16 */
    open fun List<Video>.sortVideos(): List<Video> = sort()

    @Deprecated("Use .sortVideos() instead", replaceWith = ReplaceWith("sortVideos"))
    protected open fun List<Video>.sort(): List<Video> = this

    /** The url of a lib 14 [video] whose url is only found on its page. @since extensions-lib 1.5 */
    open suspend fun getVideoUrl(video: Video): String =
        client.newCall(videoUrlRequest(video)).awaitSuccess().let { videoUrlParse(it) }

    protected open fun videoUrlRequest(video: Video): Request = GET(video.url, headers)

    protected open fun videoUrlParse(response: Response): String = throw UnsupportedOperationException()

    @Suppress("Unused")
    fun SEpisode.setUrlWithoutDomain(url: String) {
        this.url = getUrlWithoutDomain(url)
    }

    @Suppress("Unused")
    fun SAnime.setUrlWithoutDomain(url: String) {
        this.url = getUrlWithoutDomain(url)
    }

    private fun getUrlWithoutDomain(orig: String): String {
        return try {
            val uri = URI(orig)
            var out = uri.path
            if (uri.query != null) {
                out += "?" + uri.query
            }
            if (uri.fragment != null) {
                out += "#" + uri.fragment
            }
            out
        } catch (_: URISyntaxException) {
            orig
        }
    }

    /** @since extensions-lib 14 */
    open fun getAnimeUrl(anime: SAnime): String = animeDetailsRequest(anime).url.toString()

    /** @since extensions-lib 14 */
    @Suppress("Unused")
    open fun getEpisodeUrl(episode: SEpisode): String = episode.url

    @Deprecated("All modifications should be done when constructing the episode")
    open fun prepareNewEpisode(episode: SEpisode, anime: SAnime) {}
}
