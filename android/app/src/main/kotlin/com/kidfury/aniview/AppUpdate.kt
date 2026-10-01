package com.kidfury.aniview

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.widget.Toast
import java.io.File

/**
 * Installs a downloaded update APK through a PackageInstaller session: Android shows its own "Update AniView?"
 * prompt straight away (no notification to find, which TVs barely show). From Android 12, once AniView installed
 * itself this way, later updates need no prompt at all. Either way the app closes when it's replaced; the
 * notification posted afterwards opens it again.
 */
object AppUpdate {
    fun install(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (Build.VERSION.SDK_INT >= 31) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("aniview.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val status = Intent(context, AppUpdateReceiver::class.java).setAction(ACTION_STATUS)
            // Mutable: the installer fills in the status extras.
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            session.commit(PendingIntent.getBroadcast(context, id, status, flags).intentSender)
        }
    }

    const val ACTION_STATUS = "com.kidfury.aniview.UPDATE_STATUS"
}

/** The install session's answers (show Android's prompt, or say why it failed), and "updated" once replaced. */
class AppUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) return updated(context)
        if (intent.action != AppUpdate.ACTION_STATUS) return
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val prompt = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                context.startActivity(prompt.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            PackageInstaller.STATUS_SUCCESS -> {}
            PackageInstaller.STATUS_FAILURE_ABORTED -> {} // "Cancel" on the prompt
            else -> Toast.makeText(
                context,
                "Update failed: ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "unknown error"}",
                Toast.LENGTH_LONG,
            ).show()
        }
    }

    private fun updated(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = "app_updates"
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(channel, "App updates", NotificationManager.IMPORTANCE_DEFAULT),
            )
            Notification.Builder(context, channel)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val version = context.packageManager.getPackageInfo(context.packageName, 0).versionName
        val open = PendingIntent.getActivity(
            context, 0, context.packageManager.getLaunchIntentForPackage(context.packageName),
            PendingIntent.FLAG_IMMUTABLE,
        )
        manager.notify(
            2026,
            builder.setSmallIcon(android.R.drawable.stat_sys_download_done)
                .setContentTitle("AniView updated to $version")
                .setContentText("Tap to open")
                .setContentIntent(open)
                .setAutoCancel(true)
                .build(),
        )
    }
}
