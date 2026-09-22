package com.kidfury.aniview

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.tv.TvContract.WatchNextPrograms
import android.os.Build

/**
 * The TV launcher's "Continue watching" row, mirrored from the app's watch history. Shown by the Android TV home;
 * Google TV shows only apps Google has certified for it.
 */
object WatchNext {
    const val EXTRA_RESUME_ID = "resume_media_id"

    /** Replaces this app's rows with [entries]: {id, title, episode, image, position, duration, at}, newest first. */
    fun sync(context: Context, entries: List<*>) {
        if (Build.VERSION.SDK_INT < 26) return
        val resolver = context.contentResolver
        // The TV provider scopes an app's delete to its own rows.
        resolver.delete(WatchNextPrograms.CONTENT_URI, null, null)
        for (entry in entries) {
            val e = entry as Map<*, *>
            val id = (e["id"] as Number).toInt()
            val position = (e["position"] as Number?)?.toLong() ?: 0L
            val values = ContentValues().apply {
                put(WatchNextPrograms.COLUMN_TYPE, WatchNextPrograms.TYPE_TV_EPISODE)
                // A saved spot continues it; a finished episode leaves the next one queued at 0.
                put(
                    WatchNextPrograms.COLUMN_WATCH_NEXT_TYPE,
                    if (position > 0) WatchNextPrograms.WATCH_NEXT_TYPE_CONTINUE else WatchNextPrograms.WATCH_NEXT_TYPE_NEXT,
                )
                put(WatchNextPrograms.COLUMN_TITLE, e["title"] as String)
                put(WatchNextPrograms.COLUMN_EPISODE_DISPLAY_NUMBER, e["episode"] as String)
                (e["image"] as String?)?.let {
                    put(WatchNextPrograms.COLUMN_POSTER_ART_URI, it)
                    put(WatchNextPrograms.COLUMN_POSTER_ART_ASPECT_RATIO, WatchNextPrograms.ASPECT_RATIO_2_3)
                }
                if (position > 0) put(WatchNextPrograms.COLUMN_LAST_PLAYBACK_POSITION_MILLIS, position.toInt())
                (e["duration"] as Number?)?.let { put(WatchNextPrograms.COLUMN_DURATION_MILLIS, it.toInt()) }
                put(WatchNextPrograms.COLUMN_LAST_ENGAGEMENT_TIME_UTC_MILLIS, (e["at"] as Number).toLong())
                put(WatchNextPrograms.COLUMN_INTERNAL_PROVIDER_ID, id.toString())
                put(
                    WatchNextPrograms.COLUMN_INTENT_URI,
                    Intent(context, MainActivity::class.java)
                        .putExtra(EXTRA_RESUME_ID, id)
                        .toUri(Intent.URI_INTENT_SCHEME),
                )
            }
            resolver.insert(WatchNextPrograms.CONTENT_URI, values)
        }
    }
}
