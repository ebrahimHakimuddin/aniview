package com.kidfury.aniview

import android.app.Activity
import android.content.Context
import android.view.WindowManager
import androidx.media3.common.AudioAttributes
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Surface
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.TrackSelectionOverride
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.text.CueGroup
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

/**
 * Video playback on Media3 ExoPlayer (as CloudStream plays), drawn into a Flutter texture. Each player reports its
 * state on `aniview/exo/<id>` as maps; subtitles come back as text cues for Flutter to draw.
 */
@UnstableApi
class ExoPlayers(private val context: Context, engine: FlutterEngine) {
    private val textures = engine.renderer
    private val messenger = engine.dartExecutor.binaryMessenger
    private val players = mutableMapOf<Long, Entry>()

    init {
        MethodChannel(messenger, "aniview/exo").setMethodCallHandler { call, result ->
            val id = call.argument<Number>("id")?.toLong()
            val entry = id?.let(players::get)
            when (call.method) {
                "create" -> result.success(create())
                "open" -> {
                    entry?.open(
                        call.argument<String>("url")!!,
                        call.argument<Map<String, String>>("headers") ?: emptyMap(),
                        call.argument<Boolean>("hls") ?: false,
                        call.argument<Number>("start")?.toLong() ?: 0L,
                        call.argument<List<Map<String, String>>>("subtitles") ?: emptyList(),
                    )
                    result.success(null)
                }
                "stop" -> done(result) { entry?.stop() }
                "play" -> done(result) { entry?.player?.play() }
                "pause" -> done(result) { entry?.player?.pause() }
                "seek" -> done(result) { entry?.player?.seekTo(call.argument<Number>("ms")!!.toLong()) }
                "rate" -> done(result) { entry?.player?.setPlaybackSpeed(call.argument<Double>("rate")!!.toFloat()) }
                "subtitle" -> done(result) { entry?.subtitle(call.argument<String>("track")!!) }
                "dispose" -> {
                    entry?.release()
                    players.remove(id)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Runs [action] and answers with nothing (the codec can't send Kotlin's Unit). */
    private inline fun done(result: MethodChannel.Result, action: () -> Unit) {
        action()
        result.success(null)
    }

    private fun create(): Map<String, Long> {
        val producer = textures.createSurfaceProducer()
        val entry = Entry(producer)
        players[producer.id()] = entry
        return mapOf("id" to producer.id(), "texture" to producer.id())
    }

    private inner class Entry(private val producer: TextureRegistry.SurfaceProducer) {
        private val handler = Handler(Looper.getMainLooper())
        private var sink: EventChannel.EventSink? = null

        // Decoder fallback: a chip that can't decode the stream in hardware tries the next decoder instead of failing.
        val player: ExoPlayer = ExoPlayer.Builder(context)
            .setRenderersFactory(DefaultRenderersFactory(context).setEnableDecoderFallback(true))
            .setLoadControl(
                DefaultLoadControl.Builder()
                    // Up to two minutes ahead, as far as memory allows: fewer stalls on slow hosts.
                    .setBufferDurationsMs(30_000, 120_000, 2_500, 5_000)
                    .setPrioritizeTimeOverSizeThresholds(true)
                    .build(),
            )
            // Pauses for calls and other apps' sound, and when headphones come out.
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .build()

        private val ticker = object : Runnable {
            override fun run() {
                send(position())
                handler.postDelayed(this, 250)
            }
        }

        init {
            EventChannel(messenger, "aniview/exo/${producer.id()}").setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    sink = events
                }

                override fun onCancel(arguments: Any?) {
                    sink = null
                }
            })
            player.setVideoSurface(producer.surface)
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceAvailable() = player.setVideoSurface(producer.surface)
                override fun onSurfaceCleanup() = player.clearVideoSurface()
            })
            player.addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    send(
                        position() + mapOf(
                            "buffering" to (state == Player.STATE_BUFFERING),
                            "completed" to (state == Player.STATE_ENDED),
                        ),
                    )
                }

                override fun onIsPlayingChanged(playing: Boolean) {
                    send(mapOf("playing" to player.playWhenReady))
                    if (playing) handler.post(ticker) else handler.removeCallbacks(ticker)
                    // No screen timeout (or TV screensaver) mid-episode; it comes back while paused.
                    (context as? Activity)?.window?.let {
                        if (playing) {
                            it.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            it.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                    }
                }

                // A seek while paused moves the time shown, though nothing ticks.
                override fun onPositionDiscontinuity(
                    old: Player.PositionInfo,
                    new: Player.PositionInfo,
                    reason: Int,
                ) = send(position())

                override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
                    send(mapOf("playing" to playWhenReady))
                }

                override fun onVideoSizeChanged(size: VideoSize) {
                    if (size.width == 0 || size.height == 0) return
                    producer.setSize(size.width, size.height)
                    send(
                        mapOf(
                            "width" to size.width,
                            "height" to (size.height / size.pixelWidthHeightRatio.coerceAtLeast(0.01f)).toInt(),
                        ),
                    )
                }

                override fun onTracksChanged(tracks: Tracks) = send(mapOf("tracks" to textTracks(tracks)))

                override fun onCues(cues: CueGroup) {
                    send(mapOf("cues" to cues.cues.mapNotNull { it.text?.toString() }.joinToString("\n")))
                }

                override fun onPlayerError(error: PlaybackException) {
                    send(mapOf("error" to (error.message ?: error.errorCodeName)))
                }
            })
        }

        fun open(url: String, headers: Map<String, String>, hls: Boolean, startMs: Long, subtitles: List<Map<String, String>>) {
            val http = DefaultHttpDataSource.Factory()
                .setAllowCrossProtocolRedirects(true)
                .setDefaultRequestProperties(headers)
                .apply { headers["User-Agent"]?.let(::setUserAgent) }
            val uri = if (url.startsWith("/")) Uri.fromFile(File(url)) else Uri.parse(url)
            val item = MediaItem.Builder()
                .setUri(uri)
                .apply { if (hls) setMimeType(MimeTypes.APPLICATION_M3U8) }
                .setSubtitleConfigurations(
                    subtitles.mapIndexed { i, s ->
                        MediaItem.SubtitleConfiguration.Builder(Uri.parse(s["url"]))
                            .setId("external:$i")
                            .setLabel(s["label"])
                            .setMimeType(subtitleMime(s["url"]!!))
                            .build()
                    },
                )
                .build()
            player.setMediaSource(DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http)).createMediaSource(item), startMs)
            player.prepare()
            player.playWhenReady = true
        }

        /** "off", "auto" (the stream's default), or a track id from [textTracks]. */
        fun subtitle(track: String) {
            val builder = player.trackSelectionParameters.buildUpon()
                .clearOverridesOfType(C.TRACK_TYPE_TEXT)
                .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, track == "off")
            if (track != "off" && track != "auto") {
                val (group, index) = track.split(":").map(String::toInt)
                player.currentTracks.groups.getOrNull(group)?.let {
                    builder.setOverrideForType(TrackSelectionOverride(it.mediaTrackGroup, index))
                }
            } else if (track == "auto") {
                builder.setSelectUndeterminedTextLanguage(true)
            }
            player.trackSelectionParameters = builder.build()
        }

        private fun textTracks(tracks: Tracks) = tracks.groups.withIndex()
            .filter { it.value.type == C.TRACK_TYPE_TEXT }
            .flatMap { (g, group) ->
                (0 until group.length).map { i ->
                    val format = group.getTrackFormat(i)
                    mapOf(
                        "id" to "$g:$i",
                        "title" to format.label,
                        "language" to format.language,
                        "selected" to group.isTrackSelected(i),
                    )
                }
            }

        private fun position(): Map<String, Any> = mapOf(
            "position" to player.currentPosition,
            "duration" to player.duration.let { if (it == C.TIME_UNSET) 0L else it },
            "buffer" to player.bufferedPosition,
        )

        private fun send(event: Map<String, Any?>) {
            sink?.success(event)
        }

        fun stop() {
            handler.removeCallbacks(ticker)
            player.stop()
            player.clearMediaItems()
        }

        fun release() {
            handler.removeCallbacks(ticker)
            (context as? Activity)?.window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            player.release()
            producer.release()
        }
    }

    private fun subtitleMime(url: String) = when (url.substringBefore('?').substringAfterLast('.').lowercase()) {
        "srt" -> MimeTypes.APPLICATION_SUBRIP
        "ass", "ssa" -> MimeTypes.TEXT_SSA
        "ttml", "xml", "dfxp" -> MimeTypes.APPLICATION_TTML
        else -> MimeTypes.TEXT_VTT
    }
}

