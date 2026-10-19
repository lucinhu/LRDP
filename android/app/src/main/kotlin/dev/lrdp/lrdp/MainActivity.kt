package dev.lrdp.lrdp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var audioChannel: MethodChannel? = null
    private var displayChannel: MethodChannel? = null
    private var displayToken: Long? = null
    private var frameRateLimit: Int? = null
    private var originalRefreshRate: Float? = null
    private var focusRequest: AudioFocusRequest? = null
    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private var activeToken: Long? = null
    private var resumed = false
    private val audioManager get() = getSystemService(Context.AUDIO_SERVICE) as AudioManager

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        volumeControlStream = AudioManager.STREAM_MUSIC
        displayChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.lrdp/display").also { channel ->
            channel.setMethodCallHandler { call, result ->
                if (call.method != "frameRate") {
                    result.notImplemented()
                } else {
                    val token = call.argument<Number>("token")?.toLong()
                    val limit = call.argument<Number>("limit")?.toInt()
                    val active = call.argument<Boolean>("active")
                    if (token == null || limit == null || limit !in 0..240 || active == null) {
                        result.error("invalid_rate", "Invalid display preference", null)
                    } else {
                        if (active) {
                            displayToken = token
                            frameRateLimit = limit
                        } else if (displayToken == token) {
                            displayToken = null
                            frameRateLimit = null
                        }
                        applyDisplayPreference()
                        result.success(null)
                    }
                }
            }
        }
        audioChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.lrdp/audio_focus").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        val token = call.argument<Number>("token")?.toLong()
                        if (token == null) result.error("invalid_token", "Invalid audio request", null)
                        else result.success(requestFocus(token))
                    }
                    "release" -> {
                        val token = call.argument<Number>("token")?.toLong()
                        if (token == null || token == activeToken) releaseFocus()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun applyDisplayPreference() {
        try {
            val attributes = window.attributes
            val limit = frameRateLimit
            if (!resumed || limit == null) {
                originalRefreshRate?.let {
                    attributes.preferredRefreshRate = it
                    window.attributes = attributes
                }
                if (limit == null) originalRefreshRate = null
                return
            }
            if (originalRefreshRate == null) originalRefreshRate = attributes.preferredRefreshRate
            val display = windowManager.defaultDisplay
            val current = display.mode
            val rates = display.supportedModes.filter {
                it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight
            }.map { it.refreshRate }.sorted()
            // Request a rate capable of displaying the selected cap, while
            // preserving resolution. Battery/OS policy remains authoritative.
            val target = if (limit == 0) rates.filter { it <= 240.1f }.lastOrNull()
                else rates.firstOrNull { it >= limit - 0.1f } ?: rates.lastOrNull()
            attributes.preferredRefreshRate = target ?: display.refreshRate
            window.attributes = attributes
        } catch (_: RuntimeException) {
            // Some displays do not permit applications to choose a refresh rate.
        }
    }

    private fun changed(token: Long, granted: Boolean) {
        if (token == activeToken) {
            audioChannel?.invokeMethod("changed", mapOf("token" to token, "granted" to granted))
        }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(token: Long): Boolean {
        releaseFocus()
        if (!resumed) return false
        activeToken = token
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            changed(token, resumed && change == AudioManager.AUDIOFOCUS_GAIN)
        }
        focusListener = listener
        return try {
            val status = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_UNKNOWN).build())
                    .setWillPauseWhenDucked(true)
                    .setAcceptsDelayedFocusGain(true)
                    .setOnAudioFocusChangeListener(listener)
                    .build()
                focusRequest = request
                audioManager.requestAudioFocus(request)
            } else {
                audioManager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
            }
            status == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        } catch (_: RuntimeException) {
            releaseFocus()
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun releaseFocus() {
        activeToken?.let { changed(it, false) }
        activeToken = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            focusListener?.let { audioManager.abandonAudioFocus(it) }
        }
        focusRequest = null
        focusListener = null
    }

    override fun onResume() {
        resumed = true
        super.onResume()
        applyDisplayPreference()
    }

    override fun onPause() {
        resumed = false
        applyDisplayPreference()
        releaseFocus()
        super.onPause()
    }

    override fun onDestroy() {
        frameRateLimit = null
        applyDisplayPreference()
        displayChannel?.setMethodCallHandler(null)
        displayChannel = null
        releaseFocus()
        audioChannel?.setMethodCallHandler(null)
        audioChannel = null
        super.onDestroy()
    }
}
