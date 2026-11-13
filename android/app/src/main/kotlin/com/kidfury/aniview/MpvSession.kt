package com.kidfury.aniview

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.PowerManager
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * What Media3 does for its own player (see ExoPlayers.kt), for a video that plays through mpv instead, as one does
 * while Anime4K upscaling is on: audio focus, a pause when headphones come out, the screen kept on and the network
 * awake while it plays. Dart's mpv backend (exo.dart) tells it `playing` (true/false) and `end` on `aniview/mpv`;
 * it calls `pause` back, and `play` once a call or another app's sound that paused it for a moment is over.
 * There is one mpv for the app's run, so one session at a time.
 */
class MpvSession(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "aniview/mpv")
    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focused = false
    private var playing = false

    /** Paused for a moment's loss of focus, to play on when it comes back. */
    private var resumeOnGain = false

    private val onFocus = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                focused = false
                resumeOnGain = false
                pause()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> if (playing) {
                resumeOnGain = true
                pause()
            }
            // Android lowers the sound itself for a notification.
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> Unit
            AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnGain) {
                resumeOnGain = false
                channel.invokeMethod("play", null)
            }
        }
    }

    private val focusRequest: AudioFocusRequest? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build(),
                )
                .setOnAudioFocusChangeListener(onFocus)
                .build()
        } else {
            null
        }

    private val noisy = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) pause()
        }
    }
    private var noisyRegistered = false

    // As Media3's WAKE_MODE_NETWORK: the CPU and Wi-Fi stay up while it plays, so the stream keeps coming with the
    // screen off.
    private val wake = (activity.getSystemService(Context.POWER_SERVICE) as PowerManager)
        .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aniview:mpv")
        .apply { setReferenceCounted(false) }

    @Suppress("DEPRECATION") // WIFI_MODE_FULL_HIGH_PERF is what Media3's WifiLockManager takes too
    private val wifi = (activity.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
        .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "aniview:mpv")
        .apply { setReferenceCounted(false) }

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "playing" -> playing(call.arguments as Boolean)
                "end" -> end()
                else -> return@setMethodCallHandler result.notImplemented()
            }
            result.success(null)
        }
    }

    private fun pause() = channel.invokeMethod("pause", null)

    private fun playing(now: Boolean) {
        playing = now
        if (now) {
            if (!focused && !requestFocus()) {
                // A call holds the audio: as Media3, don't play over it.
                pause()
                return
            }
            if (!noisyRegistered) {
                val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    activity.registerReceiver(noisy, filter, Context.RECEIVER_NOT_EXPORTED)
                } else {
                    activity.registerReceiver(noisy, filter)
                }
                noisyRegistered = true
            }
            if (!wake.isHeld) wake.acquire()
            if (!wifi.isHeld) wifi.acquire()
            activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            releaseLocks()
            // No screen timeout (or TV screensaver) mid-episode; it comes back while paused, as with Media3.
            activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }

    /** The player closed: the audio goes back to whoever wants it. */
    private fun end() {
        playing = false
        resumeOnGain = false
        if (focused) {
            if (focusRequest != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audio.abandonAudioFocusRequest(focusRequest)
            } else {
                @Suppress("DEPRECATION")
                audio.abandonAudioFocus(onFocus)
            }
            focused = false
        }
        if (noisyRegistered) {
            activity.unregisterReceiver(noisy)
            noisyRegistered = false
        }
        releaseLocks()
        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun requestFocus(): Boolean {
        val granted = if (focusRequest != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audio.requestAudioFocus(focusRequest)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(onFocus, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        focused = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return focused
    }

    private fun releaseLocks() {
        if (wake.isHeld) wake.release()
        if (wifi.isHeld) wifi.release()
    }
}
