package com.kidfury.aniview

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Background check for new episodes, with the app closed and across reboots. Every hour (when online) it asks
 * AniList which episodes aired since the last successful check, for the shows on your AniList watching list plus
 * the recently watched ones the app handed over (see lib/notifications.dart), and posts a notification for each.
 * A failed check leaves the window open, so the next one catches up.
 */
// ponytail: hourly, so a notification can be up to an hour late (longer in Doze); exact alarms if that ever matters
class EpisodeJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread {
            try {
                check(this)
            } catch (_: Exception) {
                // offline or AniList down: last_check stays put and the next run covers this window
            }
            jobFinished(params, false)
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters) = true

    companion object {
        const val EXTRA_MEDIA_ID = "media_id"
        private const val JOB_ID = 7
        private const val CHANNEL = "episodes"
        private const val MAX_WINDOW = 24 * 60 * 60L // after days offline, don't announce last week's episodes

        private fun prefs(context: Context) =
            context.getSharedPreferences("episode_notifications", Context.MODE_PRIVATE)

        /**
         * [json] is {enabled, ids: recently watched AniList ids, token: AniList token or null when signed out,
         * user: AniList user id or null when unknown}. Checking starts from now, so turning it on doesn't announce
         * old episodes.
         */
        fun configure(context: Context, json: String) {
            val config = JSONObject(json)
            val jobs = context.getSystemService(JobScheduler::class.java)
            val prefs = prefs(context)
            val edit = prefs.edit().putString("ids", config.getJSONArray("ids").toString())
            if (config.isNull("token")) {
                edit.remove("token").remove("user")
            } else {
                edit.putString("token", config.getString("token"))
                if (!config.isNull("user")) edit.putInt("user", config.getInt("user"))
            }
            if (!prefs.contains("last_check")) edit.putLong("last_check", System.currentTimeMillis() / 1000)
            edit.apply()

            val nothingToWatch = config.getJSONArray("ids").length() == 0 && config.isNull("token")
            if (!config.getBoolean("enabled") || nothingToWatch) {
                jobs.cancel(JOB_ID)
                prefs.edit().remove("last_check").apply()
                return
            }
            if (jobs.getPendingJob(JOB_ID) != null) return
            jobs.schedule(
                JobInfo.Builder(JOB_ID, ComponentName(context, EpisodeJob::class.java))
                    .setPeriodic(60 * 60 * 1000L)
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setPersisted(true)
                    .build(),
            )
        }

        private fun check(context: Context) {
            val prefs = prefs(context)
            val now = System.currentTimeMillis() / 1000
            val from = maxOf(prefs.getLong("last_check", now), now - MAX_WINDOW)
            val ids = JSONArray(prefs.getString("ids", "[]"))
            val token = prefs.getString("token", null)
            val user = prefs.getInt("user", 0)
            if (token != null && user != 0) {
                try {
                    val lists = anilist(
                        "query(\$u:Int){MediaListCollection(userId:\$u,type:ANIME,status_in:[CURRENT,REPEATING])" +
                            "{lists{entries{mediaId}}}}",
                        JSONObject().put("u", user),
                        token,
                    ).getJSONObject("MediaListCollection").getJSONArray("lists")
                    for (i in 0 until lists.length()) {
                        val entries = lists.getJSONObject(i).getJSONArray("entries")
                        for (j in 0 until entries.length()) ids.put(entries.getJSONObject(j).getInt("mediaId"))
                    }
                } catch (_: Exception) {
                    // signed out on the web (expired token): still check the recently watched shows
                }
            }
            if (ids.length() > 0 && from < now) {
                val aired = anilist(
                    "query(\$ids:[Int],\$from:Int,\$to:Int){Page(perPage:50){airingSchedules(mediaId_in:\$ids," +
                        "airingAt_greater:\$from,airingAt_lesser:\$to,sort:TIME){episode media{id title{userPreferred}}}}}",
                    JSONObject().put("ids", ids).put("from", from).put("to", now + 1),
                    null,
                ).getJSONObject("Page").getJSONArray("airingSchedules")
                for (i in 0 until aired.length()) post(context, aired.getJSONObject(i))
            }
            prefs.edit().putLong("last_check", now).apply()
        }

        private fun anilist(query: String, variables: JSONObject, token: String?): JSONObject {
            val connection = URL("https://graphql.anilist.co").openConnection() as HttpURLConnection
            try {
                connection.requestMethod = "POST"
                connection.connectTimeout = 15_000
                connection.readTimeout = 15_000
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setRequestProperty("Accept", "application/json")
                if (token != null) connection.setRequestProperty("Authorization", "Bearer $token")
                connection.outputStream.use {
                    it.write(JSONObject().put("query", query).put("variables", variables).toString().toByteArray())
                }
                if (connection.responseCode != 200) throw Exception("AniList: HTTP ${connection.responseCode}")
                return JSONObject(connection.inputStream.bufferedReader().use { it.readText() }).getJSONObject("data")
            } finally {
                connection.disconnect()
            }
        }

        private fun post(context: Context, airing: JSONObject) {
            if (Build.VERSION.SDK_INT >= 33 &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                return
            }
            val manager = context.getSystemService(NotificationManager::class.java)
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(
                    NotificationChannel(CHANNEL, "New episodes", NotificationManager.IMPORTANCE_DEFAULT),
                )
                Notification.Builder(context, CHANNEL)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }
            val episode = airing.getInt("episode")
            val media = airing.getJSONObject("media")
            val id = media.getInt("id")
            val notificationId = "$id-$episode".hashCode()
            // Opens the show's page (see MainActivity); the request code keeps each notification's extra apart.
            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
                .putExtra(EXTRA_MEDIA_ID, id)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            manager.notify(
                notificationId,
                builder.setSmallIcon(android.R.drawable.ic_media_play)
                    .setContentTitle("Episode $episode is out")
                    .setContentText(media.getJSONObject("title").optString("userPreferred"))
                    .setAutoCancel(true)
                    .setContentIntent(
                        PendingIntent.getActivity(
                            context,
                            notificationId,
                            open,
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                        ),
                    )
                    .build(),
            )
        }
    }
}
