package com.kidfury.aniview

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.InAppMp4Muxer
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * Turns a downloaded episode (a local HLS playlist, its segments maybe AES-128 encrypted) into one MP4, and copies
 * that into Movies/AniView so it shows up in the gallery.
 */
object GalleryExport {
    /**
     * Writes the episode in [dir] to [out] as an MP4 without re-encoding, then calls [done] with why it couldn't, or
     * null. Media3 reads the playlist as the player does (keys, odd timestamps and all), so what it writes plays in
     * the player too; Android's own extractor and muxer made files whose audio the player turned down.
     * Call on the main thread.
     */
    fun toMp4(context: Context, dir: File, out: File, done: (String?) -> Unit) {
        out.delete()
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(File(dir, "index.m3u8")))
            .setMimeType(MimeTypes.APPLICATION_M3U8)
            .build()
        Transformer.Builder(context)
            // Android's MediaMuxer only splits a frame's slices at 4-byte start codes; TS often uses 3-byte ones, so
            // every slice after the first was lost and the picture went green below its top strip.
            .setMuxerFactory(InAppMp4Muxer.Factory())
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) = done(null)

                override fun onError(composition: Composition, exportResult: ExportResult, exportException: ExportException) {
                    out.delete()
                    done(exportException.message ?: "Couldn't make the MP4")
                }
            })
            .build()
            .start(EditedMediaItem.Builder(item).build(), out.path)
    }

    // ponytail: MediaStore paths need Android 10+; older phones would need the storage permission flow
    /** Copies [video] (an MP4, or a torrent's MKV) into the gallery as [name]; returns the copy's address, to delete it by later. */
    fun save(context: Context, video: File, name: String): String {
        if (Build.VERSION.SDK_INT < 29) throw IllegalStateException("Saving to the gallery needs Android 10 or newer")
        val resolver = context.contentResolver
        val mkv = video.extension.equals("mkv", ignoreCase = true)
        val uri = resolver.insert(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            ContentValues().apply {
                put(MediaStore.Video.Media.DISPLAY_NAME, if (mkv) "$name.mkv" else "$name.mp4")
                put(MediaStore.Video.Media.MIME_TYPE, if (mkv) "video/x-matroska" else "video/mp4")
                put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/AniView")
                put(MediaStore.Video.Media.IS_PENDING, 1)
            },
        ) ?: throw IllegalStateException("Couldn't create the gallery file")
        try {
            resolver.openOutputStream(uri, "w")!!.use { output -> video.inputStream().use { it.copyTo(output) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri.toString()
    }

    /** Deletes a copy [save] made; gone already (deleted in the gallery) is fine. */
    fun delete(context: Context, uri: String) {
        context.contentResolver.delete(Uri.parse(uri), null, null)
    }
}
