package com.kidfury.aniview

import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build

/** Gives a completed update its own install action; DownloadManager's private download notification is not an installer. */
class UpdateDownloadReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != DownloadManager.ACTION_DOWNLOAD_COMPLETE) return
        val id = intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1)
        val prefs = context.getSharedPreferences("app_update", Context.MODE_PRIVATE)
        if (id < 0 || id != prefs.getLong("download_id", -1)) return
        prefs.edit().remove("download_id").apply()

        val downloads = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val cursor = downloads.query(DownloadManager.Query().setFilterById(id))
        val complete = cursor.use {
            it.moveToFirst() && it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)) ==
                DownloadManager.STATUS_SUCCESSFUL
        }
        val apk = if (complete) downloads.getUriForDownloadedFile(id) else null
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = "app_updates"
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(channel, "App updates", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, channel) else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val action = if (apk != null) {
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(apk, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        } else {
            Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val pending = PendingIntent.getActivity(
            context, 0, action, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        manager.notify(
            2026,
            builder.setSmallIcon(if (apk != null) android.R.drawable.stat_sys_download_done else android.R.drawable.stat_notify_error)
                .setContentTitle(if (apk != null) "AniView update ready" else "AniView update failed")
                .setContentText(if (apk != null) "Tap to install" else "Tap to view downloads")
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build(),
        )
    }
}
