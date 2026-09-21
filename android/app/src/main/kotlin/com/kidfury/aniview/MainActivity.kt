package com.kidfury.aniview

import android.Manifest
import android.app.DownloadManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.AudioManager
import android.os.Build
import android.os.Parcelable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var notifications: MethodChannel? = null
    private var externalResult: MethodChannel.Result? = null

    /** A new-episode notification tapped while the app is already running. */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val id = intent.getIntExtra(EpisodeJob.EXTRA_MEDIA_ID, 0)
        if (id != 0) notifications?.invokeMethod("open", id)
    }

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aniview/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "version" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                    "abi" -> result.success(Build.SUPPORTED_ABIS.first())
                    // For the analytics user agent, e.g. "Android 14; Pixel 7".
                    "device" -> result.success("Android ${Build.VERSION.RELEASE}; ${Build.MODEL}")
                    // The system notification opens the installer when tapped.
                    "download" -> {
                        val request = DownloadManager.Request(Uri.parse(call.argument<String>("url")))
                            .setTitle(call.argument<String>("title"))
                            .setMimeType("application/vnd.android.package-archive")
                            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                        (getSystemService(DOWNLOAD_SERVICE) as DownloadManager).enqueue(request)
                        result.success(null)
                    }
                    "external" -> playExternal(call.arguments as Map<*, *>, result)
                    "gallery" -> Thread {
                        val error = try {
                            GalleryExport.save(this, java.io.File(call.argument<String>("dir")!!), call.argument<String>("name")!!)
                            null
                        } catch (e: Exception) {
                            e.message ?: "Couldn't save to the gallery"
                        }
                        runOnUiThread { if (error == null) result.success(null) else result.error("gallery", error, null) }
                    }.start()
                    "open" -> {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(call.arguments as String)))
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        notifications = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aniview/notifications").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "configure" -> EpisodeJob.configure(this@MainActivity, call.arguments as String)
                    "permission" -> if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
                    }
                    // The show of the notification that launched the app, handed out once.
                    "launchMedia" -> {
                        val id = intent.getIntExtra(EpisodeJob.EXTRA_MEDIA_ID, 0)
                        intent.removeExtra(EpisodeJob.EXTRA_MEDIA_ID)
                        return@setMethodCallHandler result.success(if (id == 0) null else id)
                    }
                    else -> return@setMethodCallHandler result.notImplemented()
                }
                result.success(null)
            }
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

    /**
     * Hands a stream to another video app. MX Player and VLC take the title, start position and subtitles, and
     * report where playback stopped, which comes back as {position, duration, completed} (empty from other apps).
     */
    private fun playExternal(args: Map<*, *>, result: MethodChannel.Result) {
        val subtitles = args["subtitles"] as List<*>
        val intent = Intent(Intent.ACTION_VIEW)
            .setDataAndType(Uri.parse(args["url"] as String), "video/*")
            .putExtra("title", args["title"] as String)
            .putExtra("position", (args["position"] as Number).toInt())
            .putExtra("return_result", true)
        @Suppress("UNCHECKED_CAST")
        (args["headers"] as Map<String, String>?)?.let { headers ->
            intent.putExtra("headers", headers.flatMap { listOf(it.key, it.value) }.toTypedArray())
        }
        if (subtitles.isNotEmpty()) {
            // Parcelable[], not Array<Uri>, which would be sent as a Serializable that MX Player ignores.
            val uris = subtitles.map<Any?, Parcelable> { Uri.parse((it as Map<*, *>)["url"] as String) }
            intent.putExtra("subs", uris.toTypedArray())
                .putExtra("subs.name", subtitles.map { (it as Map<*, *>)["label"] as String }.toTypedArray())
                .putExtra("subs.enable", arrayOf<Parcelable>(uris.first()))
                .putExtra("subtitles_location", uris.first().toString())
        }
        try {
            startActivityForResult(intent, EXTERNAL_REQUEST)
            externalResult?.success(emptyMap<String, Any>())
            externalResult = result
        } catch (_: ActivityNotFoundException) {
            result.error("no_player", "No video player app is installed", null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != EXTERNAL_REQUEST) return
        val extras = data?.extras
        // MX Player: position/duration as Int ms; VLC: extra_position/extra_duration as Long ms.
        fun ms(vararg keys: String) = keys.firstNotNullOfOrNull { key ->
            (extras?.get(key) as? Number)?.toLong()
        }
        externalResult?.success(
            mapOf(
                "position" to ms("position", "extra_position"),
                "duration" to ms("duration", "extra_duration"),
                "completed" to (extras?.getString("end_by") == "playback_completion"),
            ),
        )
        externalResult = null
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
        const val EXTERNAL_REQUEST = 1
    }
}
