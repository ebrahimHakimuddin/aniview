package com.kidfury.aniview

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aniview/downloads")
            .setMethodCallHandler { call, result ->
                showDownload(
                    call.method,
                    call.argument<String>("title") ?: "",
                    call.argument<String>("text"),
                    call.argument<Int>("percent") ?: 0,
                )
                result.success(null)
            }
        // The player's brightness/volume swipe drives the phone's media volume, not mpv's.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aniview/volume")
            .setMethodCallHandler { call, result ->
                val audio = getSystemService(AUDIO_SERVICE) as AudioManager
                val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                if (call.method == "set") {
                    val level = Math.round((call.arguments as Double) * max).toInt()
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC, level, 0)
                }
                result.success(audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max)
            }
    }

    /** One ongoing notification while an episode downloads, then a dismissable one saying how it ended. */
    private fun showDownload(state: String, title: String, text: String?, percent: Int) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (state != "progress") manager.cancel(PROGRESS_ID)
        if (state == "cancel") return
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            if (state == "progress" && percent == 0) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
            }
            return
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW),
            )
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder.setContentTitle(title).setContentIntent(
            PendingIntent.getActivity(
                this, 0, packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE,
            ),
        )
        if (state == "progress") {
            builder.setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentText("Downloading · $percent%")
                .setProgress(100, percent, percent == 0)
                .setOngoing(true)
            manager.notify(PROGRESS_ID, builder.build())
        } else {
            builder.setSmallIcon(
                if (state == "done") android.R.drawable.stat_sys_download_done else android.R.drawable.stat_notify_error,
            )
                .setContentText(text ?: if (state == "done") "Downloaded" else "Download failed")
                .setAutoCancel(true)
            manager.notify(title.hashCode(), builder.build())
        }
    }

    private companion object {
        const val CHANNEL = "downloads"
        const val PROGRESS_ID = 1
    }
}
