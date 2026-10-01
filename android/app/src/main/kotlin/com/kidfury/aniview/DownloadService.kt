package com.kidfury.aniview

import android.app.Notification
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.PowerManager

/**
 * Keeps the app alive while the download queue runs (the downloads themselves run in Dart, see lib/downloads.dart),
 * so Android doesn't freeze them once the app is in the background. Its notification is the download's progress.
 * Started with the first episode's progress and stopped when the queue is empty.
 */
// ponytail: closing the app from recents still stops downloads (Dart dies with the activity); they resume next launch
class DownloadService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?) = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = pending ?: return START_NOT_STICKY.also { stopSelf() }
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(PROGRESS_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(PROGRESS_ID, notification)
        }
        // The screen going off mustn't sleep the CPU mid-segment.
        if (wakeLock == null) {
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aniview:downloads")
                .apply { acquire(6 * 60 * 60 * 1000L) }
        }
        return START_NOT_STICKY
    }

    /** Android 15 allows a data sync service 6 hours a day; the rest of the queue waits for the app to be opened. */
    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()

    override fun onTaskRemoved(rootIntent: Intent?) = stopSelf()

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        running = false
        super.onDestroy()
    }

    companion object {
        const val PROGRESS_ID = 1
        private var pending: Notification? = null
        private var running = false

        /** Starts the service showing [notification]; false when it was already running (or Android refused). */
        fun start(context: Context, notification: Notification): Boolean {
            if (running) return false
            pending = notification
            return try {
                val intent = Intent(context, DownloadService::class.java)
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
                running = true
                true
            } catch (_: Exception) {
                false // started from the background on Android 12+: downloads go on while the app stays alive
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadService::class.java))
        }
    }
}
